#!/usr/bin/env python3
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path(__file__).resolve().parent.parent
load=lambda name:[json.loads(x)for x in (root/f'results/{name}.jsonl').read_text().splitlines()]
rows=[x for x in load('soak-fixed')if x['type']=='pass']
fig,axes=plt.subplots(1,3,figsize=(13,3.5),layout='constrained')
hours=[x['pass']/6 for x in rows]
for k,label in [('rss','RSS'),('footprint','Physical footprint'),('malloc_in_use','Live malloc')]:axes[0].plot(hours,[x['metrics'][k]/1048576 for x in rows],label=label)
axes[0].axvspan(0,10/6,color='gray',alpha=.12,label='Warm-up');axes[0].set(xlabel='Processed media hours',ylabel='MiB',title='Release soak, no forced collection');axes[0].legend(fontsize=8)
for name,label in [('callback-unfixed','Original'),('callback-fixed','Per-session cleanup')]:
 r=[x for x in load(name)if x['type']=='pass'];axes[1].plot([x['pass']for x in r],[x['metrics']['callbacks']['ffmpeg_complete']for x in r],label=label)
axes[1].set(xlabel='Completed sessions',ylabel='Registered callbacks',title='Completed callbacks must be released');axes[1].legend(fontsize=8)
counts=[];heaps=[]
for mode in ['unfixed','fixed']:
 r=json.loads((root/f'results/profile-{mode}-heap-final.json').read_text());counts.append(next(x['instances']for x in r['interesting']if x['class']=='PcmAnalysis'));heaps.append(r['heap']['heapUsage']/1048576)
axes[2].bar(['Original','Cleanup'],counts,color=['#c65353','#3a8c73']);axes[2].set(ylabel='Live PcmAnalysis instances',title='After 100 sessions and diagnostic GC')
for i,(n,h)in enumerate(zip(counts,heaps)):axes[2].text(i,n+2,f'{n} objects\nheap {h:.2f} MiB',ha='center',fontsize=9)
axes[2].set_ylim(0,125)
for ax in axes:ax.grid(axis='y',alpha=.2);ax.spines[['top','right']].set_visible(False)
fig.savefig(root/'results/memory.svg');fig.savefig(root/'work/memory.png',dpi=140)
(root/'work/plot-version.txt').write_text(matplotlib.__version__+'\n')
