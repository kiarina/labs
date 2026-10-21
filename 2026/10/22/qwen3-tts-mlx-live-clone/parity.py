"""Numerical gate on identical float32 reference inputs, independent of timings."""
import argparse
import json
from pathlib import Path
import mlx.core as mx
import numpy as np
import soundfile as sf
from bench import load
from inputs import REF_TEXT,TEXT
from live import prepare_clone,full_prompt,ClonePrompt,TextSource,generate_live

p=argparse.ArgumentParser();p.add_argument('--output',default='output');args=p.parse_args();root=Path(args.output)
f=dict(np.load(root/'torch-fixture.npz'));model=load('float32')
audio,sr=sf.read(root/'reference.wav',dtype='float32');assert sr==24000
prompt=prepare_clone(model,mx.array(audio),REF_TEXT)
report={}
def compare(name,a,b):
    a=np.asarray(a,dtype=np.float64);b=np.asarray(b,dtype=np.float64)
    if a.shape!=b.shape: report[name]={'shape_a':list(a.shape),'shape_b':list(b.shape)};return
    diff=a-b;report[name]={'max_abs':float(np.abs(diff).max()),'mean_abs':float(np.abs(diff).mean()),
        'relative_l2':float(np.linalg.norm(diff)/(np.linalg.norm(b)+1e-30)),
        'cosine':float(a.ravel()@b.ravel()/(np.linalg.norm(a)*np.linalg.norm(b)+1e-30))}
    return report[name]
# Isolated layout/embedding gate: same reference codes and prefix supplied to
# both backends. Speaker/codec extraction has its own end-to-end observation.
config=model.config.talker_config;codes=mx.array(f['ref_codes'].T[None])
codec=model.talker.get_input_embeddings()(codes[:,0,:])
for i in range(config.num_code_groups-1):codec=codec+model.talker.code_predictor.codec_embedding[i](codes[:,i+1,:])
bos=model.talker.get_input_embeddings()(mx.array([[config.codec_bos_id]]));codec=mx.concatenate([bos,codec],axis=1)
p2=ClonePrompt(mx.array(f['inputs'][:,:prompt.prefix.shape[1]]),f['ref_ids'].tolist(),codes,codec,mx.array(f['pad']),prompt.eos)
inputs,trailing=full_prompt(model,p2,f['target_ids'].tolist());mx.eval(inputs,trailing)
compare('isolated_prompt',np.array(inputs),f['inputs']);compare('isolated_trailing',np.array(trailing),f['trailing'])
# Talker gate gets the identical PT embeddings, excluding upstream extraction.
logits,_=model.talker(mx.array(f['inputs']),cache=model.talker.make_cache());mx.eval(logits)
a=np.array(logits[:,-1]);b=f['logits'];compare('talker_same_input',a,b)
report['greedy_first_code_equal']=bool(np.argmax(a)==np.argmax(b))
def softmax(x):
    x=x.astype(np.float64)/.9;x=x-x.max(-1,keepdims=True);x=np.exp(x);return x/x.sum(-1,keepdims=True)
p_,q=softmax(b),softmax(a);report['logits_kl']=float((p_*(np.log(p_+1e-30)-np.log(q+1e-30))).sum())
# End-to-end prompt observation, intentionally includes independent encoders.
own_inputs,own_tail=full_prompt(model,prompt,model.tokenizer.encode(TEXT,add_special_tokens=False));mx.eval(own_inputs,own_tail)
compare('independent_prompt',np.array(own_inputs),f['inputs']);compare('independent_trailing',np.array(own_tail),f['trailing'])
own_codes=np.array(prompt.ref_codes)[0].T
report['ref_code_equal']=bool(np.array_equal(own_codes,f['ref_codes']))
report['ref_code_match_fraction']=float(np.mean(own_codes==f['ref_codes']))
source=TextSource(model.tokenizer);source.push(TEXT);source.close();trace={}
generator=generate_live(model,p2,source,temperature=0,trace=trace)
try:
    for _ in generator:
        if len(trace['codes'])>=len(f['greedy_codes']):break
finally:generator.close()
report['greedy_frames']=len(f['greedy_codes'])
report['greedy_all_codebooks_equal']=bool(np.array_equal(np.array(trace['codes'])[:len(f['greedy_codes'])],f['greedy_codes']))
report['gate_pass']=bool(report['isolated_prompt']['max_abs']<1e-4 and report['isolated_trailing']['max_abs']<1e-4 and report['talker_same_input']['cosine']>.999999 and report['logits_kl']<1e-6 and report['greedy_first_code_equal'] and report['greedy_all_codebooks_equal'])
(root/'float32-parity.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
if not report['gate_pass']:raise SystemExit('Float32 parity gate failed')
