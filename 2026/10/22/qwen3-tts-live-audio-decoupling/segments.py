"""Control: finish small text spans independently, preserving the full reference."""
import re
import time
from live import TextSource
from boundary import prepare_boundary_session
from decouple import generate
from state import snapshot, restore


def boundary(text, language, closed):
    minimum=8 if language=='ja' else 14
    for match in re.finditer(r'[、。！？!?.,;:]\s*',text):
        if match.end()>=minimum:return match.end()
    if language=='en':
        spaces=list(re.finditer(r'\s+',text))
        if len(spaces)>=6:return spaces[5].end()
    elif len(text)>=24:return 24
    return len(text) if closed else 0


def generate_segments(model,prompt,source,session,case,trace,cached=False):
    trace.update(codes=[],waits=[],commits=[],pads=[],segments=[])
    start=time.perf_counter();cursor=0;first=True
    saved=snapshot(model,session) if cached else None
    while True:
        with source.condition:
            if source.cancelled:raise InterruptedError('Canceled')
            available=source.text[cursor:];closed=source.closed;version=source.version
        n=boundary(available,case,closed)
        if n:
            piece=available[:n];cursor+=n
            if not first:session=restore(model,session,saved) if cached else prepare_boundary_session(model,prompt,'fresh_prefix')
            first=False
            span=TextSource(model.tokenizer);span.push(piece);span.close();part={}
            begin=time.perf_counter()-start
            for pcm in generate(model,prompt,span,session,'strict',part):yield pcm
            trace['codes'].extend(part['codes'])
            trace['segments'].append({'start':begin,'end':time.perf_counter()-start,'chars':n,
                'through_chars':cursor,'frames':len(part['codes']),'stop':part.get('stop')})
        elif closed:
            trace.update(stop='eos',consumed_target_tokens=len(model.tokenizer.encode(source.text,add_special_tokens=False)),
                target_tokens=len(model.tokenizer.encode(source.text,add_special_tokens=False)))
            return
        else:
            before=time.perf_counter()-start;source.wait(version)
            trace['waits'].append({'start':before,'end':time.perf_counter()-start,'phase':'segment'})
