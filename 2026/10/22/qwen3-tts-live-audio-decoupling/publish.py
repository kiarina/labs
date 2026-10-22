"""Publish aggregate diagnostics, never private reference or ASR hypotheses."""
import argparse
import json
import statistics
from pathlib import Path


def main():
    p=argparse.ArgumentParser();p.add_argument('outputs',nargs='+',type=Path);p.add_argument('--destination',default='results')
    a=p.parse_args();out=Path(a.destination);out.mkdir(exist_ok=True)
    rows=[];environments={};warmups=[]
    for folder in a.outputs:
        environments[folder.name]=json.loads((folder/'environment.json').read_text())
        evaluation=folder/'evaluation.json'
        scores={r['file']:r for r in json.loads(evaluation.read_text())['scores']} if evaluation.exists() else {}
        for row in json.loads((folder/'results.json').read_text()):
            stem=f"{row['mode']}-{row['case']}-{row['schedule']}-{row['seed']}"
            score=dict(scores.get(stem+'.wav',{}));score.pop('asr',None)
            row=dict(row,run=folder.name,evaluation=score)
            row['token_counts_basis']='whole-input bookkeeping; segment tokenizations differ' if row['mode'].startswith('segments') else 'generation trace'
            raw=json.loads((folder/(stem+'.json')).read_text())
            row['segments']=raw['trace'].get('segments',[])
            rows.append(row)
        warm=folder/'strict-ja-full-0.json'
        if warm.exists():warmups.append(dict(json.loads(warm.read_text())['result'],run=folder.name))
    (out/'measurements.json').write_text(json.dumps({'environments':environments,'measurements':rows,'warmups_excluded':warmups},ensure_ascii=False,indent=2)+'\n')
    summary=[]
    for case in ['ja','en']:
        for mode in ['strict','pad4','pad12','pad_free','segments','segments_cached']:
            group=[r for r in rows if r['case']==case and r['mode']==mode and r['schedule']=='chars']
            if not group:continue
            # No duplicated case/mode/seed is counted as a new independent seed.
            unique={r['seed']:r for r in group};group=list(unique.values())
            item={'case':case,'mode':mode,'seeds':sorted(unique),'n':len(group),
                  'failures':sum(r['error'] is not None for r in group)}
            for key in ['first_pcm_s','gap_s','audio_s','wait_s']:
                values=[r[key] for r in group if key in r]
                item[key+'_median']=statistics.median(values)
                item[key+'_range']=[min(values),max(values)]
            for key in ['cer','wer','ecapa_cos']:
                values=[r['evaluation'][key] for r in group if r['evaluation'].get(key) is not None]
                if values:item[key+'_mean']=statistics.mean(values)
            summary.append(item)
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    for row in summary:print(row)
if __name__=='__main__':main()
