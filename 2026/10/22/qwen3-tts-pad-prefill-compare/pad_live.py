"""Experimental reference PAD prefill. Not a trained/equivalent layout claim."""
import time
from dataclasses import dataclass
import mlx.core as mx
from live import embed

@dataclass
class PadSession:
    cache: object
    bridge: object
    prepared_rows: int
    prep_s: float


def prepare_pad_session(model,prompt,mode):
    start=time.perf_counter()
    length=prompt.codec_embeds.shape[1]
    rows=length-1 if mode=='pad_last' else length
    if len(prompt.ref_text_ids)>rows:
        raise ValueError('Reference text longer than PAD-prefill region; never truncate it')
    reference=embed(model,prompt.ref_text_ids)
    text=mx.concatenate([reference,mx.broadcast_to(prompt.pad,(1,rows-reference.shape[1],reference.shape[2]))],axis=1)
    prefill=mx.concatenate([prompt.prefix,text+prompt.codec_embeds[:,:rows]],axis=1)
    if mode=='pad_restart':
        text_bos=embed(model,[model.config.tts_bos_token_id])
        codec_pad=model.talker.get_input_embeddings()(mx.array([[model.config.talker_config.codec_pad_id]]))
        prefill=mx.concatenate([prefill,text_bos+codec_pad],axis=1)
    cache=model.talker.make_cache()
    logits,hidden=model.talker(prefill,cache=cache)
    mx.eval(logits,hidden)
    decoder=model.speech_tokenizer.decoder
    decoder.reset_streaming_state()
    mx.eval(decoder.streaming_step(prompt.ref_codes))
    if mode=='pad_last':bridge=prompt.codec_embeds[:,-1:]
    elif mode=='pad_restart':
        bridge=model.talker.get_input_embeddings()(mx.array([[model.config.talker_config.codec_bos_id]]))
    elif mode=='pad_extra':
        bridge=model.talker.get_input_embeddings()(mx.array([[model.config.talker_config.codec_pad_id]]))
    else:raise ValueError(mode)
    mx.eval(bridge)
    return PadSession(cache,bridge,int(prefill.shape[1]),time.perf_counter()-start)


def generate_pad(model,prompt,source,session,*,emit_frames=4,max_frames=500,temperature=.9,trace=None,require_text_consumed=True):
    trace=trace if trace is not None else {}
    trace.update(codes=[],waits=[],commits=[],prepared_rows=session.prepared_rows)
    start=time.perf_counter();stamp=lambda:time.perf_counter()-start
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
        if ids:break
        if closed:raise ValueError('No target text')
        source.wait(version)
    inputs=embed(model,[ids[0]])+session.bridge
    cursor=1;cache=session.cache;code_cache=model.talker.code_predictor.make_cache()
    decoder=model.speech_tokenizer.decoder
    trace['prefill']={'t':stamp(),'target_tokens':len(ids),'required_prefix_tokens':1,'cached_rows':session.prepared_rows}
    generated=[];first_ids=[];emitted=0
    eos=model.config.talker_config.codec_eos_token_id;suppress=model._suppress_codec_tokens(eos)
    try:
        for step in range(max_frames):
            logits,hidden=model.talker(inputs,cache=cache)
            ids,closed,_=poll()
            token=model._sample_token(logits,temperature=temperature,top_k=50,top_p=1.,repetition_penalty=1.05,
                repetition_context_size=max(1,len(first_ids)),generated_tokens=first_ids or None,
                suppress_tokens=suppress+([] if closed and (not require_text_consumed or cursor>len(ids)) else [eos]))
            mx.eval(token)
            if int(token[0,0])==eos:
                trace['stop']='eos';trace['target_tokens']=len(ids);trace['consumed_target_tokens']=min(cursor,len(ids));trace['eos_row_fed']=cursor>len(ids);break
            parts,codes=model._predict_code_tokens(token,hidden,temperature=temperature,top_k=50,top_p=1.,code_cache=code_cache)
            mx.eval(codes);first_ids.append(int(token[0,0]));generated.append(codes);trace['codes'].append(codes[0].tolist())
            if len(generated)-emitted>=emit_frames:
                block=mx.transpose(mx.stack(generated[emitted:],axis=1),(0,2,1))
                pcm=decoder.streaming_step(block).squeeze(1)[0];mx.eval(pcm)
                emitted=len(generated);yield pcm
            while True:
                ids,closed,version=poll()
                if cursor<len(ids):next_text=embed(model,[ids[cursor]]);break
                if closed:
                    next_text=prompt.eos if cursor==len(ids) else prompt.pad;break
                before=stamp();source.wait(version);trace['waits'].append({'start':before,'end':stamp()})
            inputs=next_text+model._codec_embeds_for_tokens(parts)
            mx.eval(inputs);cursor+=1
        else:
            trace['stop']='frame_cap';raise RuntimeError('max_frames reached before EOS')
        if len(generated)>emitted:
            block=mx.transpose(mx.stack(generated[emitted:],axis=1),(0,2,1))
            pcm=decoder.streaming_step(block).squeeze(1)[0];mx.eval(pcm);yield pcm
    finally:decoder.reset_streaming_state()
