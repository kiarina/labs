"""Where does the long-text loop start, and how far ahead had text been fed?

For each long-text output: Whisper word timestamps give a time for every heard
character. The anchor is the end of the first `しんどいって` (the point after
which looping runs jump back). From the trace, the talker had generated
round(t * 12.5) frames by then; every frame consumed one text row, so the target
tokens fed = min(required + frames, target tokens). The speech had reached the
token covering that anchor, so lead = fed - spoken. Loops are counted as in
summarize.py. Writes loop_lead.json without any ASR text.
"""
import argparse
import json
import unicodedata
from pathlib import Path

import mlx_whisper
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model

from bench import MODEL, REV
from evaluate import ASR, ASR_REV, audio, normalize

ANCHOR='しんどいって'
LOOP_PHRASE='ゆっくりでいいからね'
FRAME_RATE=12.5

p=argparse.ArgumentParser();p.add_argument('--output',default='output');p.add_argument('--cases',nargs='+',default=['long']);args=p.parse_args()
root=Path(args.output);rows=json.loads((root/'results.json').read_text())
tokenizer=load_model(snapshot_download(MODEL,revision=REV)).tokenizer
asr=snapshot_download(ASR,revision=ASR_REV)
report=[]
for r in rows:
 if r['case'] not in args.cases or r.get('error'):continue
 stem=f"{r['mode']}-{r['case']}-{r['schedule']}-{r['seed']}"
 out=mlx_whisper.transcribe(audio(root/f'{stem}.wav'),path_or_hf_repo=asr,language='ja',temperature=0.,word_timestamps=True)
 chars=[(c,w['start']) for s in out['segments'] for w in s['words'] for c in normalize(w['word'])]
 heard=''.join(c for c,_ in chars)
 loop=heard.count(LOOP_PHRASE)>=2
 i=heard.find(ANCHOR)
 # Spoken target position: the anchor's end inside the target text.
 target=r['text'];anchor_end=target.find(ANCHOR)+len(ANCHOR)
 enc=tokenizer(target,add_special_tokens=False,return_offsets_mapping=True)
 spoken=next(k for k,(a,b) in enumerate(enc['offset_mapping']) if b>=anchor_end)+1
 trace=json.loads((root/f'{stem}.json').read_text())['trace']
 n=len(enc['input_ids']);required=r['required_prefix_tokens']
 item={'stem':stem,'mode':r['mode'],'schedule':r['schedule'],'seed':r['seed'],'interval_s':r['interval_s'],'loop':loop,'anchor_heard':i>=0,'target_tokens':n,'spoken_tokens_at_anchor':spoken}
 if i>=0:
  t=chars[i+len(ANCHOR)-1][1];frames=round(t*FRAME_RATE)
  fed=min(required+frames,n) if r['mode']!='icl' else n
  item.update(anchor_audio_s=round(t,2),frames_at_anchor=frames,fed_tokens_at_anchor=fed,lead_tokens=fed-spoken,
   all_text_fed_before_anchor=fed>=n,total_frames=len(trace['codes']))
 report.append(item);print(json.dumps(item,ensure_ascii=False),flush=True)
(root/'loop_lead.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
