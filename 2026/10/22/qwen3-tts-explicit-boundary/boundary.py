"""Explicit reference-end / target-start candidates; experimental layouts."""
import time
import mlx.core as mx
from live import embed
from pad_live import PadSession

MODES=['pad_restart','text_end','audio_end','both_end','fresh_prefix']

def prepare_boundary_session(model,prompt,mode):
    if mode not in MODES:raise ValueError(mode)
    start=time.perf_counter();length=int(prompt.codec_embeds.shape[1])
    end_text=mode in ['text_end','both_end','fresh_prefix']
    end_audio=mode in ['audio_end','both_end','fresh_prefix']
    text=embed(model,prompt.ref_text_ids)
    if end_text:text=mx.concatenate([text,prompt.eos],axis=1)
    assert text.shape[1]<=length,'Never truncate reference text'
    text=mx.concatenate([text,mx.broadcast_to(prompt.pad,(1,length-text.shape[1],text.shape[-1]))],axis=1)
    parts=[prompt.prefix,text+prompt.codec_embeds]
    cfg=model.config.talker_config
    codec=lambda token:model.talker.get_input_embeddings()(mx.array([[token]]))
    if end_audio:parts.append(prompt.pad+codec(cfg.codec_eos_token_id))
    if mode=='fresh_prefix':
        # role + language + same full-reference speaker + ttsBOS/codecPAD.
        # Replaces, rather than duplicates, the ordinary restart row.
        parts.append(prompt.prefix)
    else:
        parts.append(embed(model,[model.config.tts_bos_token_id])+codec(cfg.codec_pad_id))
    prefill=mx.concatenate(parts,axis=1);cache=model.talker.make_cache()
    logits,hidden=model.talker(prefill,cache=cache);mx.eval(logits,hidden)
    decoder=model.speech_tokenizer.decoder;decoder.reset_streaming_state()
    # EOS is a talker special token, never an acoustic code sent to decoder.
    mx.eval(decoder.streaming_step(prompt.ref_codes))
    bridge=codec(cfg.codec_bos_id);mx.eval(bridge)
    return PadSession(cache,bridge,int(prefill.shape[1]),time.perf_counter()-start,1)
