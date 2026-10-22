"""Independent copy of prepared model state; adapted from kiapi live helpers."""
import copy
import mlx.core as mx
from pad_live import PadSession


def clone(value):
    if isinstance(value,mx.array):return mx.array(value)
    if isinstance(value,list):return [clone(x) for x in value]
    if isinstance(value,tuple):return tuple(clone(x) for x in value)
    if isinstance(value,dict):return {k:clone(v) for k,v in value.items()}
    if hasattr(value,'state'):
        other=copy.copy(value);other.state=clone(value.state);return other
    return copy.copy(value)


def snapshot(model,session):
    decoder=model.speech_tokenizer.decoder
    state={name:{key:clone(getattr(module,key)) for key in ('_buffer','_overflow','_transformer_cache') if hasattr(module,key)}
           for name,module in decoder.named_modules()}
    return clone(session.cache),state


def restore(model,session,saved):
    decoder=model.speech_tokenizer.decoder;decoder.reset_streaming_state()
    # The decoder may be a compile wrapper; use actual modules, including root.
    modules=dict(decoder.named_modules())
    cache,state=saved
    for name,values in state.items():
        for key,value in values.items():setattr(modules[name],key,clone(value))
    return PadSession(clone(cache),session.bridge,session.prepared_rows,session.prep_s,session.required_tokens)
