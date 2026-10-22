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
    required_tokens: int = 1


def prepare_pad_session(model,prompt,mode):
    start=time.perf_counter()
    length=prompt.codec_embeds.shape[1]
    hold=int(mode.removeprefix('pad_hold')) if mode.startswith('pad_hold') else (1 if mode=='pad_last' else 0)
    rows=length-hold
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
    if hold:bridge=prompt.codec_embeds[:,-hold:]
    elif mode=='pad_restart':
        bridge=model.talker.get_input_embeddings()(mx.array([[model.config.talker_config.codec_bos_id]]))
    elif mode=='pad_extra':
        bridge=model.talker.get_input_embeddings()(mx.array([[model.config.talker_config.codec_pad_id]]))
    else:raise ValueError(mode)
    mx.eval(bridge)
    return PadSession(cache,bridge,int(prefill.shape[1]),time.perf_counter()-start,hold or 1)


def generate_pad(model,prompt,source,session,*,emit_frames=4,max_frames=500,temperature=.9,trace=None,require_text_consumed=True,pace=1):
    # pace=N: after the start rows, feed a real text row at most every N frames
    # and a TTS PAD text row on the frames between (untrained; N=1 is unchanged).
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
        if ids and (closed or len(ids)>=session.required_tokens):break
        if closed:raise ValueError('No target text')
        source.wait(version)
    needed=session.required_tokens
    text=embed(model,ids[:needed])
    if len(ids)<needed:
        assert closed
        text=mx.concatenate([text,prompt.eos],axis=1)
        if text.shape[1]<needed:text=mx.concatenate([text,mx.broadcast_to(prompt.pad,(1,needed-text.shape[1],text.shape[-1]))],axis=1)
    inputs=text+session.bridge
    cache=session.cache
    # mlx-audio's multi-row mask ignores an existing cache offset. Advance held
    # reference rows one at a time, without sampling, then generate on the last.
    for row in range(needed-1):
        logits,hidden=model.talker(inputs[:,row:row+1],cache=cache)
        mx.eval(logits,hidden)
    inputs=inputs[:,-1:]
    cursor=needed;code_cache=model.talker.code_predictor.make_cache()
    decoder=model.speech_tokenizer.decoder
    trace['prefill']={'t':stamp(),'target_tokens':len(ids),'required_prefix_tokens':session.required_tokens,'cached_rows':session.prepared_rows}
    generated=[];first_ids=[];emitted=0;since=0
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
            if since<pace-1:
                next_text=prompt.pad;since+=1
            else:
                while True:
                    ids,closed,version=poll()
                    if cursor<len(ids):next_text=embed(model,[ids[cursor]]);break
                    if closed:
                        next_text=prompt.eos if cursor==len(ids) else prompt.pad;break
                    before=stamp();source.wait(version);trace['waits'].append({'start':before,'end':stamp()})
                cursor+=1;since=0
            inputs=next_text+model._codec_embeds_for_tokens(parts)
            mx.eval(inputs)
        else:
            trace['stop']='frame_cap';raise RuntimeError('max_frames reached before EOS')
        if len(generated)>emitted:
            block=mx.transpose(mx.stack(generated[emitted:],axis=1),(0,2,1))
            pcm=decoder.streaming_step(block).squeeze(1)[0];mx.eval(pcm);yield pcm
    finally:decoder.reset_streaming_state()


def prepare_lookahead_session(model,prompt,k):
    """pad_restart, but show the first k target tokens over codec_PAD before codec_BOS.

    Rows after the reference: [tts_BOS + codec_PAD], [t1..tk + codec_PAD],
    [t(k+1) + codec_BOS], then one target token per generated frame. k=0 is
    exactly pad_restart. generate_pad overlays the first k+1 real tokens on
    this bridge and advances the extra rows one at a time without sampling.
    """
    session=prepare_pad_session(model,prompt,'pad_restart')
    if k:
        pad=model.talker.get_input_embeddings()(mx.array([[model.config.talker_config.codec_pad_id]]))
        session.bridge=mx.concatenate([mx.broadcast_to(pad,(1,k,pad.shape[-1])),session.bridge],axis=1)
        mx.eval(session.bridge)
    session.required_tokens=k+1
    return session
