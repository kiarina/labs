"""Independent float32 CPU reference: official causal ICL prompt and logits."""
import argparse
import importlib.metadata
import json
from pathlib import Path
import numpy as np
import soundfile as sf
import torch
from huggingface_hub import snapshot_download
from qwen_tts import Qwen3TTSModel

p=argparse.ArgumentParser();p.add_argument('--audio',default='../output/reference.wav');p.add_argument('--output',default='../output/torch-fixture.npz');args=p.parse_args()
REF='もしもし、もう駅に着いた？こっちはまだ電車。あと5分くらいかな。助かる。今日は結構寒いね。'
TEXT='こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？'
repo='Qwen/Qwen3-TTS-12Hz-1.7B-Base';rev='fd4b254389122332181a7c3db7f27e918eec64e3'
torch.set_num_threads(4)
model=Qwen3TTSModel.from_pretrained(snapshot_download(repo,revision=rev),device_map='cpu',dtype=torch.float32,attn_implementation='sdpa')
with torch.inference_mode():
    prompt=model.create_voice_clone_prompt(ref_audio=args.audio,ref_text=REF)
    prompt_dict=model._prompt_items_to_voice_clone_prompt(prompt)
    ids=model._tokenize_texts([model._build_assistant_text(TEXT)])
    ref_ids=model._tokenize_texts([model._build_ref_text(REF)])
    core=model.model
    class Captured(Exception): pass
    captured={}
    original=core.talker.generate
    def capture(**kwargs):
        captured.update(kwargs);raise Captured
    core.talker.generate=capture
    try:
        model.generate_voice_clone(text=TEXT,language='Japanese',voice_clone_prompt=prompt,non_streaming_mode=False)
    except Captured: pass
    finally: core.talker.generate=original
    inputs=captured['inputs_embeds'];mask=captured['attention_mask']
    trailing=captured['trailing_text_hidden'];pad=captured['tts_pad_embed']
    result=core.talker(inputs_embeds=inputs,attention_mask=mask,use_cache=False)
    out={'inputs':inputs.numpy(),'trailing':trailing.numpy(),'pad':pad.numpy(),'logits':result.logits[:,-1].numpy(),
         'target_ids':ids[0][0,3:-5].numpy(),'ref_ids':ref_ids[0][0,3:-2].numpy(),
         'ref_codes':prompt_dict['ref_code'][0].numpy()}
    greedy,_=core.generate(input_ids=ids,ref_ids=ref_ids,voice_clone_prompt=prompt_dict,
        languages=['Japanese'],non_streaming_mode=False,max_new_tokens=16,
        do_sample=False,subtalker_dosample=False)
    out['greedy_codes']=greedy[0].cpu().numpy()
    np.savez(args.output,**out)
    meta={'repo':repo,'revision':rev,'dtype':'float32','device':'cpu','attention':'sdpa',
          'versions':{p:importlib.metadata.version(p) for p in ['qwen-tts','torch','transformers']},
          'shapes':{k:list(v.shape) for k,v in out.items()}}
    Path(args.output).with_suffix('.json').write_text(json.dumps(meta,indent=2));print(meta,flush=True)
