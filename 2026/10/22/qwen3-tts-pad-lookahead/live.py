"""Lab-local live-input adapter for mlx-audio Qwen3-TTS Base ICL cloning.

Uses the causal (non_streaming_mode=False) reference layout. All model work is
on the consumer thread. Producers only append Unicode text to a condition.
"""
from __future__ import annotations
import threading
import time
from dataclasses import dataclass
import mlx.core as mx


class TextSource:
    def __init__(self, tokenizer, max_chars=65536):
        self.tokenizer=tokenizer; self.max_chars=max_chars
        self.text=''; self.closed=False; self.cancelled=False
        self.ids=[]; self.condition=threading.Condition(); self.version=0

    def push(self, fragment):
        with self.condition:
            if self.closed or self.cancelled: raise RuntimeError('Text source is no longer writable')
            if len(self.text)+len(fragment)>self.max_chars: raise ValueError('Text source character budget exceeded')
            self.text+=fragment; self.version+=1; self.condition.notify_all()

    def close(self):
        with self.condition:
            self.closed=True; self.version+=1; self.condition.notify_all()

    def cancel(self):
        with self.condition:
            self.cancelled=True; self.version+=1; self.condition.notify_all()

    def poll(self):
        with self.condition:
            if self.cancelled: raise InterruptedError('Generation cancelled')
            text=self.text; closed=self.closed; version=self.version
        pieces=self.tokenizer.backend_tokenizer.pre_tokenizer.pre_tokenize_str(text)
        # The last regex pre-token may still grow with a future fragment. BPE
        # merges never cross pre-token boundaries; retain that piece as lookahead.
        boundary=len(text) if closed else (pieces[-1][1][0] if pieces else 0)
        ids=self.tokenizer.encode(text[:boundary],add_special_tokens=False)
        if ids[:len(self.ids)]!=self.ids:
            raise RuntimeError('Tokenizer revised committed prefix; refuse unsafe continuation')
        self.ids=ids
        return ids,closed,version

    def wait(self, version, timeout=30):
        with self.condition:
            changed=self.condition.wait_for(lambda:self.version!=version or self.cancelled,timeout)
            if not changed: raise TimeoutError(f'No new text for {timeout:g} seconds; explicit close() required')


def embed(model, ids):
    return model.talker.text_projection(model.talker.get_text_embeddings()(mx.array([ids])))


@dataclass
class ClonePrompt:
    prefix: object
    ref_text_ids: list
    ref_codes: object
    codec_embeds: object
    pad: object
    eos: object

    @property
    def required_prefix_tokens(self):
        return max(0,self.codec_embeds.shape[1]-len(self.ref_text_ids))


def prepare_clone(model, audio, transcript, language='japanese', speaker_audio=None):
    # Reuse mlx-audio's speaker extraction and role/language prefix, then rebuild
    # its ICL section in the causal reference layout instead of full-text prefill.
    # speaker_audio: take the x-vector from this (the unmodified reference) while
    # the ICL codes come from `audio`, e.g. the reference plus trailing silence.
    if speaker_audio is None:
        original,_,pad,codes=model._prepare_icl_generation_inputs('',audio,transcript,language)
    else:
        vector=model.extract_speaker_embedding(speaker_audio)
        model.extract_speaker_embedding=lambda _audio:vector
        try:
            original,_,pad,codes=model._prepare_icl_generation_inputs('',audio,transcript,language)
        finally:
            del model.extract_speaker_embedding
    ref_ids=model.tokenizer.encode(f'<|im_start|>assistant\n{transcript}<|im_end|>\n')[3:-2]
    n=len(ref_ids)+1+codes.shape[2]+1
    prefix=original[:,:original.shape[1]-n]
    codec=model.talker.get_input_embeddings()(codes[:,0,:])
    for i in range(model.config.talker_config.num_code_groups-1):
        codec=codec+model.talker.code_predictor.codec_embedding[i](codes[:,i+1,:])
    bos=model.talker.get_input_embeddings()(mx.array([[model.config.talker_config.codec_bos_id]]))
    codec=mx.concatenate([bos,codec],axis=1)
    eos=embed(model,[model.config.tts_eos_token_id])
    mx.eval(prefix,codec,pad,codes,eos)
    return ClonePrompt(prefix,ref_ids,codes,codec,pad,eos)


def full_prompt(model,prompt,target_ids):
    """Reference-compatible full causal prompt, also exported for float32 parity."""
    text=mx.concatenate([embed(model,prompt.ref_text_ids+target_ids),prompt.eos],axis=1)
    length=prompt.codec_embeds.shape[1]
    if text.shape[1]<length:
        text=mx.concatenate([text,mx.broadcast_to(prompt.pad,(1,length-text.shape[1],text.shape[-1]))],axis=1)
    inputs=mx.concatenate([prompt.prefix,text[:,:length]+prompt.codec_embeds],axis=1)
    trailing=text[:,length:] if text.shape[1]>length else prompt.pad
    return inputs,trailing


def generate_live(model,prompt,source,*,emit_frames=4,max_frames=1000,temperature=0.9,trace=None,require_text_consumed=True):
    """Yield float32 PCM arrays while preserving a single talker/code/decoder state.

    ICL needs enough initial target tokens to cover reference-code prefill.
    If closed earlier, complete the original prompt with EOS/pad exactly as in
    full-input causal ICL. It never invents pad conditioning while input is open.
    """
    trace=trace if trace is not None else {}
    trace.update(codes=[],prefill=None,waits=[],commits=[])
    start=time.perf_counter(); stamp=lambda:time.perf_counter()-start
    observed=0
    def poll():
        nonlocal observed
        ids,closed,version=source.poll()
        if len(ids)!=observed:
            trace['commits'].append({'t':stamp(),'tokens':len(ids),'text_chars':len(source.text)})
            observed=len(ids)
        return ids,closed,version
    while True:
        ids,closed,version=poll()
        if ids and (closed or len(ids)>=prompt.required_prefix_tokens): break
        if closed: raise ValueError('No target text')
        source.wait(version)
    codec_length=prompt.codec_embeds.shape[1]
    text=embed(model,prompt.ref_text_ids+ids)
    if closed: text=mx.concatenate([text,prompt.eos],axis=1)
    if text.shape[1]<codec_length:
        text=mx.concatenate([text,mx.broadcast_to(prompt.pad,(1,codec_length-text.shape[1],text.shape[-1]))],axis=1)
    inputs=mx.concatenate([prompt.prefix,text[:,:codec_length]+prompt.codec_embeds],axis=1)
    # Absolute index in [reference text + target text + EOS]. No re-prefill.
    cursor=codec_length; cache=model.talker.make_cache(); code_cache=model.talker.code_predictor.make_cache()
    decoder=model.speech_tokenizer.decoder; decoder.reset_streaming_state()
    if prompt.ref_codes is not None:
        mx.eval(decoder.streaming_step(prompt.ref_codes))  # ICL only; discard reference audio
    trace['prefill']={'t':stamp(),'target_tokens':len(ids),'required_prefix_tokens':prompt.required_prefix_tokens}
    generated=[]; first_ids=[]; emitted=0
    config=model.config.talker_config; eos=config.codec_eos_token_id
    suppress=model._suppress_codec_tokens(eos)
    try:
        for step in range(max_frames):
            logits,hidden=model.talker(inputs,cache=cache)
            ids,closed,_=poll()
            token=model._sample_token(logits,temperature=temperature,top_k=50,top_p=1.0,
                repetition_penalty=1.05,repetition_context_size=max(1,len(first_ids)),
                generated_tokens=first_ids or None,suppress_tokens=suppress+([] if closed and (not require_text_consumed or cursor>len(prompt.ref_text_ids)+len(ids)) else [eos]))
            mx.eval(token)
            if int(token[0,0])==eos:
                trace['stop']='eos';trace['target_tokens']=len(ids);trace['consumed_target_tokens']=min(max(0,cursor-len(prompt.ref_text_ids)),len(ids));trace['eos_row_fed']=cursor>len(prompt.ref_text_ids)+len(ids);break
            parts,codes=model._predict_code_tokens(token,hidden,temperature=temperature,top_k=50,top_p=1.0,code_cache=code_cache)
            mx.eval(codes)
            first_ids.append(int(token[0,0]));generated.append(codes)
            trace['codes'].append(codes[0].tolist())
            if len(generated)-emitted>=emit_frames:
                block=mx.transpose(mx.stack(generated[emitted:],axis=1),(0,2,1))
                pcm=decoder.streaming_step(block).squeeze(1)[0];mx.eval(pcm)
                emitted=len(generated);yield pcm
            # Obtain the next text row only after emitting available PCM, so a
            # producer waiting for first audio cannot deadlock against this wait.
            while True:
                ids,closed,version=poll()
                absolute=prompt.ref_text_ids+ids
                if cursor<len(absolute):
                    next_text=embed(model,[absolute[cursor]]);break
                if closed:
                    next_text=prompt.eos if cursor==len(absolute) else prompt.pad;break
                before=stamp();source.wait(version)
                trace['waits'].append({'start':before,'end':stamp()})
            inputs=next_text+model._codec_embeds_for_tokens(parts)
            mx.eval(inputs);cursor+=1
        else:
            trace['stop']='frame_cap';raise RuntimeError('max_frames reached before EOS')
        if len(generated)>emitted:
            block=mx.transpose(mx.stack(generated[emitted:],axis=1),(0,2,1))
            pcm=decoder.streaming_step(block).squeeze(1)[0];mx.eval(pcm);yield pcm
    finally:
        decoder.reset_streaming_state()

