"""Experimental PAD-on-starvation; no changes to committed text tokens."""
import time
import mlx.core as mx
from live import embed


def generate(model, prompt, source, session, mode, trace, emit_frames=4, max_frames=500):
    budget={'strict':0,'pad4':4,'pad12':12,'pad_free':max_frames}[mode]
    trace.update(codes=[],waits=[],commits=[],pads=[],steps=[])
    origin=time.perf_counter()
    stamp=lambda:time.perf_counter()-origin
    observed=-1
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
        if closed:raise ValueError('No target')
        before=stamp();source.wait(version);trace['waits'].append({'start':before,'end':stamp(),'phase':'first'})
    inputs=embed(model,[ids[0]])+session.bridge
    cursor=1; eos_fed=False; consecutive=0; generated=[]; first_ids=[]; emitted=0
    decoder=model.speech_tokenizer.decoder
    code_cache=model.talker.code_predictor.make_cache()
    eos=model.config.talker_config.codec_eos_token_id
    suppress=model._suppress_codec_tokens(eos)
    audio_origin=stamp()
    try:
        for step in range(max_frames):
            logits,hidden=model.talker(inputs,cache=session.cache)
            ids,closed,_=poll()
            token=model._sample_token(logits,temperature=.9,top_k=50,top_p=1.,repetition_penalty=1.05,
                repetition_context_size=max(1,len(first_ids)),generated_tokens=first_ids or None,
                suppress_tokens=suppress+([] if closed and eos_fed and cursor>=len(ids) else [eos]))
            mx.eval(token)
            if int(token[0,0])==eos:
                trace.update(stop='eos',consumed_target_tokens=cursor,target_tokens=len(ids),eos_row_fed=eos_fed);break
            parts,codes=model._predict_code_tokens(token,hidden,temperature=.9,top_k=50,top_p=1.,code_cache=code_cache)
            mx.eval(codes);first_ids.append(int(token[0,0]));generated.append(codes)
            trace['codes'].append(codes[0].tolist())
            trace['steps'].append({'t':stamp(),'frame':step,'cursor':cursor,'available':len(ids),'closed':closed})
            if len(generated)-emitted>=emit_frames:
                block=mx.transpose(mx.stack(generated[emitted:],axis=1),(0,2,1))
                pcm=decoder.streaming_step(block).squeeze(1)[0];mx.eval(pcm)
                emitted=len(generated);yield pcm
            while True:
                ids,closed,version=poll()
                if cursor<len(ids):
                    next_text=embed(model,[ids[cursor]]);cursor+=1;consecutive=0;break
                if closed:
                    next_text=prompt.pad if eos_fed else prompt.eos;eos_fed=True;break
                if consecutive<budget:
                    # Do not hallucinate an arbitrarily large audio backlog at GPU speed.
                    lead=len(generated)*.08-(stamp()-audio_origin)
                    if lead>.32:
                        with source.condition:source.condition.wait(timeout=min(.02,lead-.32))
                        continue
                    next_text=prompt.pad;consecutive+=1
                    trace['pads'].append({'t':stamp(),'frame':len(generated),'cursor':cursor,'chars':len(source.text)})
                    break
                before=stamp();source.wait(version)
                trace['waits'].append({'start':before,'end':stamp(),'phase':'token','cursor':cursor})
            inputs=next_text+model._codec_embeds_for_tokens(parts);mx.eval(inputs)
        else:
            trace.update(stop='frame_cap',consumed_target_tokens=cursor,target_tokens=len(ids));raise RuntimeError('frame cap')
        if len(generated)>emitted:
            block=mx.transpose(mx.stack(generated[emitted:],axis=1),(0,2,1))
            pcm=decoder.streaming_step(block).squeeze(1)[0];mx.eval(pcm);yield pcm
    finally:decoder.reset_streaming_state()
