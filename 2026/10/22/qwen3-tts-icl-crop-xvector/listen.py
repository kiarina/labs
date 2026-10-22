"""Write output/listen.html: side-by-side listening page for seed42 character runs.

Not blinded: rows are in a fixed mode order with their measurements visible.
Notes are kept in the viewer's browser only; "Copy notes" exports them as CSV.
"""
import argparse
import html
import json
from pathlib import Path

from bench import CROPS, MODES

p=argparse.ArgumentParser();p.add_argument('--output',default='output');args=p.parse_args();root=Path(args.output)
rows=json.loads((root/'results.json').read_text())
env=json.loads((root/'environment.json').read_text())
scores={s['file']:s for s in json.loads((root/'evaluation.json').read_text())['scores']}

def fmt(v,unit='',digits=2):
 return '—' if v is None else f'{v:.{digits}f}{unit}'

def row_html(r):
 stem=f"{r['mode']}-{r['case']}-{r['schedule']}-{r['seed']}";s=scores.get(f'{stem}.wav',{})
 crop=r['mode'].removeprefix('crop-').removesuffix('-spkcrop')
 icl_s=env['crops'][crop]['audio_s'] if crop in CROPS else (env['reference_s'] if r['mode']=='icl' else 0)
 spk='crop' if r['mode'].endswith('spkcrop') else 'full'
 return f'''<tr data-id="{stem}">
<th scope="row"><code>{html.escape(r['mode'])}</code><div class="sub">ICL {icl_s:.1f}s · x-vector {spk}</div></th>
<td class="num">{r['required_prefix_tokens']}</td>
<td class="num">{fmt(r.get('first_voiced_playout_s'),'s')}</td>
<td class="num">{fmt(r.get('text_done_s'),'s')}</td>
<td class="num">{fmt(r.get('gap_s'),'s')}</td>
<td class="num">{fmt(s.get('ecapa_cos'),'',3)}</td>
<td class="num">{fmt(None if s.get('cer') is None else 100*s['cer'],'%',1)}</td>
<td><audio controls preload="none" src="{stem}-listen.wav"></audio></td>
<td><audio controls preload="none" src="{stem}-arrival.wav"></audio></td>
<td><textarea rows="2" aria-label="notes for {stem}"></textarea></td>
</tr>'''

sections=[]
for case in ['short','long']:
 picked=[r for m in MODES for r in rows if r['mode']==m and r['case']==case and r['schedule']=='chars' and r['seed']==42]
 if not picked:continue
 sections.append(f'''<section><h2>{case} · 80ms/char · seed 42</h2>
<p class="text">{html.escape(picked[0]['text'])}</p>
<div class="scroll"><table><thead><tr><th>mode</th><th>wait tokens</th><th>first voice</th><th>text.done</th><th>stall sum</th><th>ECAPA</th><th>CER</th><th>speech (joined)</th><th>as delivered</th><th>notes</th></tr></thead>
<tbody>{''.join(row_html(r) for r in picked)}</tbody></table></div></section>''')

refs=''.join(f'<li><span>{name} · {c["audio_s"]:.1f}s</span><audio controls preload="none" src="crop-{name}.wav"></audio></li>' for name,c in env['crops'].items())
page=f'''<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ICL Crop Listening</title><style>
:root{{--bg:#fafaf8;--fg:#1d1d1b;--muted:#6b6b66;--line:#ddddd6;--card:#fff}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151514;--fg:#ecece8;--muted:#9a9a93;--line:#33332f;--card:#1e1e1c}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,sans-serif}}
main{{max-width:1400px;margin:0 auto;padding:24px 16px}}
h1{{font-size:20px;margin:0 0 4px}} h2{{font-size:16px;margin:28px 0 6px}} .lead,.sub,.text{{color:var(--muted)}}
.sub{{font-size:12px}} .scroll{{overflow-x:auto}} table{{border-collapse:collapse;background:var(--card);min-width:1100px}}
th,td{{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:middle}} thead th{{font-size:12px;color:var(--muted);font-weight:600}}
.num{{text-align:right;font-variant-numeric:tabular-nums}} audio{{width:220px;height:32px}} textarea{{width:180px;font:inherit;background:var(--bg);color:var(--fg);border:1px solid var(--line)}}
ul{{list-style:none;padding:0;display:flex;flex-wrap:wrap;gap:8px 16px}} li{{display:flex;flex-direction:column;gap:2px}}
button{{font:inherit;padding:6px 12px;margin-top:16px}}
</style></head><body><main>
<h1>ICL の参照を短くする比較</h1>
<p class="lead">x-vector は参照全体（10.7 秒）から、ICL に重ねる参照だけを短くした。「as delivered」は届いた時刻どおりに無音を挟んだ再生、「speech (joined)」は声そのもの。並びは固定で、目隠しではない。first voice は入力開始からの推定（デバイス遅延は含まない）。</p>
<h2>参照（ICL に使った区間）</h2><ul><li><span>full · {env['reference_s']:.1f}s</span><audio controls preload="none" src="../.input/reference.wav"></audio></li>{refs}</ul>
{''.join(sections)}
<button id="copy">Copy notes as CSV</button>
</main><script>
const key=id=>'icl-crop-notes:'+id;
document.querySelectorAll('tr[data-id]').forEach(tr=>{{const t=tr.querySelector('textarea');
 try{{t.value=localStorage.getItem(key(tr.dataset.id))||''}}catch(e){{}}
 t.addEventListener('input',()=>{{try{{localStorage.setItem(key(tr.dataset.id),t.value)}}catch(e){{}}}})}});
document.getElementById('copy').onclick=()=>{{const lines=['file,notes'];
 document.querySelectorAll('tr[data-id]').forEach(tr=>{{const v=tr.querySelector('textarea').value;if(v)lines.push(tr.dataset.id+',"'+v.replaceAll('"','""')+'"')}});
 navigator.clipboard.writeText(lines.join('\\n'))}};
document.addEventListener('play',e=>document.querySelectorAll('audio').forEach(a=>{{if(a!==e.target)a.pause()}}),true);
</script></body></html>'''
(root/'listen.html').write_text(page)
print('wrote',root/'listen.html')
