"""Replay measured PCM arrivals, including initial hold and starvation silence."""
import argparse
import json
from pathlib import Path
import numpy as np
import soundfile as sf


def simulate(events,hold=0.):
    arrivals=[e for e in events if e['type']=='pcm']
    first=arrivals[0]['t']+hold;cursor=first;gaps=[]
    for e in arrivals:
        if e['t']>cursor+.02:gaps.append(e['t']-cursor)
        cursor=max(cursor,e['t'])+e['samples']/24000
    return {'hold_s':hold,'play_start_s':first,'gap_s':sum(gaps),'gap_count':len(gaps)}


def main():
    p=argparse.ArgumentParser();p.add_argument('folders',nargs='+',type=Path);p.add_argument('--hold',type=float,default=1.);p.add_argument('--write-audio',action='store_true');a=p.parse_args()
    rows=[]
    for folder in a.folders:
        for row in json.loads((folder/'results.json').read_text()):
            if row['mode'] not in ['strict','segments_cached'] or row['schedule'] not in ['chars','pause','recorded']:continue
            stem=f"{row['mode']}-{row['case']}-{row['schedule']}-{row['seed']}"
            events=json.loads((folder/f'{stem}.json').read_text())['events']
            rows.append({'run':folder.name,'stem':stem,'policies':[simulate(events,h) for h in [0.,.3,.6,.8,1.,1.2,1.5,2.]]})
            if a.write_audio and row['seed']==42 and row['schedule']=='chars':
                hold=0. if row['mode']=='strict' else a.hold
                audio,sr=sf.read(folder/f'{stem}.wav',dtype='float32');chunks=[];offset=0;clock=0
                arrival=[e for e in events if e['type']=='pcm'];release=round((arrival[0]['t']+hold)*sr)
                for e in arrival:
                    at=max(round(e['t']*sr),release)
                    if at>clock:chunks.append(np.zeros(at-clock,dtype=np.float32));clock=at
                    chunk=audio[offset:offset+e['samples']];chunks.append(chunk);offset+=len(chunk);clock+=len(chunk)
                sf.write(folder/f'{stem}-hold{hold:g}-arrival.wav',np.concatenate(chunks),sr,subtype='PCM_16')
    Path('results/playout.json').write_text(json.dumps(rows,indent=2)+'\n')
    for r in rows:print(r['stem'],next(p for p in r['policies'] if p['hold_s']==a.hold))
if __name__=='__main__':main()
