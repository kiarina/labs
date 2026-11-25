"""Which macOS Japanese `say` voices does ECAPA keep apart? Enroll from 3 sentences, test on 4 others, 1.0 s and full."""
import itertools, json
import numpy as np
from speaker import Ecapa, Identifier, say

import sys
VOICES = sys.argv[1].split(',')
ENROLL = ['今日はいい天気ですね。', '駅前に新しいパン屋ができたらしいよ。', '来週の予定をまだ決めていないんだ。']
TEST = ['僕は肉は牛肉がいいな。', '場所は公園のほうが楽だと思うよ。', '私、車出せるよ。三人乗れる。', 'それぞれの担当をまとめてくれる？']
ec = Ecapa()
emb = {v: [ec.embed(say(v, t, f'work/pick/{v}-e{i}.wav')) for i, t in enumerate(ENROLL)] for v in VOICES}
cent = {v: (lambda m: m / np.linalg.norm(m))(np.mean(e, 0)) for v, e in emb.items()}
sim = {f'{a}-{b}': round(float(cent[a] @ cent[b]), 3) for a, b in itertools.combinations(VOICES, 2)}
print('closest pairs', sorted(sim.items(), key=lambda kv: -kv[1])[:6])
print('most apart', sorted(sim.items(), key=lambda kv: kv[1])[:6])
for cut in (1.0, None):
    wrong = 0; margins = []
    for v in VOICES:
        for i, t in enumerate(TEST):
            x = say(v, t, f'work/pick/{v}-t{i}.wav')
            if cut: x = x[:int(16000 * cut)]
            e = ec.embed(x); s = {w: float(e @ c) for w, c in cent.items()}
            best = max(s, key=s.get); wrong += best != v
            margins.append(s[v] - max(val for w, val in s.items() if w != v))
    print('cut', cut, 'wrong', wrong, '/', len(VOICES) * len(TEST), 'min margin', round(min(margins), 3))
