"""Offline: identify faces in the scene frames with (a) one centroid per person and (b) a gallery of photos."""
import json, sys
from pathlib import Path
import cv2
from faces import Faces

HERE = Path(__file__).parent
PEOPLE = ['田中', '佐藤', '鈴木']
# Who is in each frame, left to right (None = not enrolled).
TRUTH = {k: ['田中', '佐藤', '鈴木'] for k in ['base'] + [f'f{i:02d}' for i in range(10)]}
TRUTH['f10'] = ['佐藤', '鈴木']
TRUTH['f11'] = ['田中', '佐藤', '鈴木', None]

for mode in ('centroid', 'gallery'):
    fx = Faces(mode)
    for n in PEOPLE:
        fx.enroll(n, sorted(HERE.glob(f'frames/p-{n}-*.jpg')))
    right = wrong = missed = extra = 0
    margins, rows, right_scores = [], [], []
    for key, truth in TRUTH.items():
        got = fx.identify(cv2.imread(str(HERE / f'frames/{key}.jpg')))
        names = [g['name'] for g in got]
        ok = sorted(map(str, names)) == sorted(map(str, truth))
        for g in got:
            if g['name']:  # enrolled people only: best minus second best
                s = sorted(g['scores'].values(), reverse=True)
                margins.append(round(s[0] - s[1], 3))
        lows = [g['score'] for g in got if g['name']]
        right_scores.extend(lows)
        right += ok; wrong += not ok
        rows.append(f"  {key}: {'OK ' if ok else 'NG '} truth={truth} got={[(g['name'], g['where'], g['score']) for g in got]}")
    print(f'== {mode}: frames right {right}/{right + wrong}, enrolled faces: min score {min(right_scores):.3f}, min margin {min(margins)}')
    print('\n'.join(rows))
