# 複数の gpt-live の Spirit を 1 つのグループ通話に入れる（人の発言は文字で、Spirit どうしは音声で）

Spirits Garden のグループ通話の技術検証（2026-11-26）。想定する形は次のとおり。

- グループに人 n 人と Spirit m 体がいて、通話を始めた 1 人の端末だけを使う。Spirit は全員が同時に通話を始める
- 端末のマイクの音は gpt-live へ送らない。文字起こしに話者名を付けて、各 Spirit へ文字で渡す
- Spirit の声は端末で鳴らす。ほかの Spirit には、WebRTC の音声入力として渡し、誰の声かを文字で補足する

前提の lab: [codex-gpt-live-concurrent-calls](../codex-gpt-live-concurrent-calls/)（同じ ChatGPT のログインで 4 本まで同時に張れる）、
[gpt-live-multi-speaker-notes](../../25/gpt-live-multi-speaker-notes/)（話者メモを `commentary` で入れると誰の発言か分かって答える）。

## Answer

- **v3 には「人がこう言った」を文字で入れる口がない。** `thread/realtime/appendText` は `role` を捨てて、チャネル指定のない
  `session.context.append` として送られる（Codex 0.172.0 の `codex-api/src/endpoint/realtime_websocket/methods_common.rs`。
  v3 の既定のチャネルは `speakable`）。データチャネルから直接送っても、チャネルは `speakable`・`commentary`・`developer` の 3 つだけ
  （`user` は `invalid_value` で弾かれる）。`response.create` は「Responses delegation のあるセッションだけ」と弾かれる。
  v3 は最初（openai/codex#33261、2026-07-15）からこの形で、`appendText` の `role`（#27936、2026-06-12）が効くのは v1・v2 だけ。
  1 対 1 の通話で人が打った文を送ると普通に答えるのは、自分宛ての問いを `speakable` で受けると、それに答える形で話すため
  （`probe_api.py` の宛てた問いも普通に答えた）。崩れるのは、宛てでない発言や、ほかの Spirit 宛ての問いを同じ口で渡すとき
- **3 つのチャネルはどれも「人の発言」として振る舞わない。**
  - `speakable`（＝ `appendText`）は「話す内容」になる。宛てでない発言に「You know?」と返したり、問いをそのまま読み上げたりした（「ミオはどう? キャンプ派?」）
  - `commentary` は、中に質問があると宛て先に関係なく答える（ハル宛ての問いを 8 本中 8 本のミオが答えた。「あなた宛てではない記録」と書いても 4/4）。
    話者メモのような情報だけの文なら黙る（前の lab）
  - `developer` は、質問があってもほぼ黙る（単独の確かめで 4/4）。ただし通しの会話では、ほかの Spirit 宛ての問いに 1 回答えた
- **そのため、文字だけで「この発言にこの Spirit が答える」を確実には動かせなかった。** 宛て先を正しく知っている振り分け役（scenario の `to`）を置いても、
  宛ての Spirit が答えたのは 3 つの組み方のどれでも半分以下だった（下の表）
- **Spirit の声をほかの Spirit の音声入力へ流すと、互いに聞き取って会話になった。** 相手の発言の文字起こし（`heard`）はほぼ一字一句合っていた。
  2 体では温泉に決めて終わった。ただし次の問題が出た
  - 話し始めがぶつかり、発言が細切れになる（「ハ」「ル、どう?」）。止まらずに話し続けるので、「まとまったら黙る」は効きにくい
  - 「ハル」を「春見さん」という人の名前と聞き違えた（話者メモに「ハル」と書いていても）
  - 3 体では、ほかの Spirit の台詞まで自分で演じ始めた（ソラ：「僕ハルだけど、…ミオはどう? 私はキャンプ派かな」）
  - 最初の回は、人（田中さん）に聞こうと 2 体で譲り合い続けた。呼びかけに「私には聞かずに決めて」と足すと決まった
- **文字で Spirit の発言を渡すと、止まらなくなった。** `commentary` で互いの発言を渡した回は、5 分以上 3 体が相手の言葉を言い直し続けた（`a-router-commentary-1`）

### A: 人の発言を文字で渡す（Spirit 3 体、人の発言 9 行、宛ての Spirit を正しく知っている振り分け）

| 条件 | 宛ての Spirit | 宛てでない Spirit | Spirit の発言の渡し方 | 回 | 宛てに答えた（全 5 回中） | 宛てでないのに話した |
|---|---|---|---|---|---|---|
| `router-commentary` | `speakable` | `commentary` | `commentary` | 1 | 3 回ほど（混ざって数えられない） | 暴走（5 分以上止まらない） |
| `router-developer` | `appendText`（＝ `speakable`） | `developer` | `developer` | 3 | 2・2・2（3・4 行目は 3 回とも無言・「うんうん」・問いのおうむ返し） | 1・1・0 |
| `router-mixed` | `commentary` | `developer` | `developer` | 2 | 0・0 | 0・1 |

宛ては、ハル（3 行目）・ミオ（4 行目）・全員（7 行目、3 体）・ソラ（8 行目）の 5 か所（7 行目は 3 体のうち 1 体でも答えれば 1 と数えた）。
採点はエージェントが `results/a-*.json` の発言を読んで付けた。

### B: Spirit どうしを音声でつなぐ

| 回 | Spirit | 結果 |
|---|---|---|
| `b-audio-2-1` | ハル・ミオ | 田中さんに聞こうと譲り合い続け、決まらない |
| `b-audio-2-2` | ハル・ミオ | 温泉に決まる。「ハル」を「春見さん」と聞き違え |
| `b-audio-3-1` | ハル・ミオ・ソラ | 「今回は温泉、次はキャンプ」に決まる。話し始めの衝突が多く、ほかの Spirit の台詞を演じる |

声は `work/<label>-device.wav`（端末で鳴る音。git に入れない）。

## 方法

- `group.py` — 1 つの `codex app-server`（0.172.0、ChatGPT のログイン、既定の `gpt-live-1.1-codex`）の中で Spirit ごとに thread と通話（aiortc）を張る。
  各 Spirit の送信トラックはミキサーで、ほかの Spirit の声を流し込める（自分の声は戻さない）。Spirit の声は全員分を 1 本に混ぜて端末の音として保存する。
  声は Spirit ごとに変えた（ハル `juniper`・ミオ `himari`・ソラ `spruce`）
- `probe_api.py` — 1 本の通話で、`appendText`・各チャネル・`response.create` が話させるか
- `probe_channels.py` — 独立した 4 本で、人の発言を `commentary` と `developer` で入れたときに勝手に話すか、後の問いに使えるか（2 回）
- `probe_burst.py` — 独立した通話で、ほかの Spirit 宛ての問いを含む 3 行を入れたときに勝手に話すか（間隔 1 秒・6 秒、チャネルと書き方の 4 通り × 2 回）
- `exp_a.py` — 人 2 人と Spirit 3 体の 9 行の会話（`scenario.json`）を文字で渡す。人の発言は文字起こしの遅れなしで 1 秒おきに渡す
- `exp_b.py` — 人の声（macOS の `say`、Kyoko）で 1 回だけ話題を出し、あとは Spirit の声だけを互いへ流す。話者メモは `commentary` で、話し始め（`turn.created`）に送る。90 秒

```bash
uv venv .venv && uv pip install --python .venv aiortc==1.16.0 numpy   # av 19.0.2, numpy 2.5.5
.venv/bin/python probe_api.py
.venv/bin/python probe_channels.py channels-1
.venv/bin/python probe_burst.py burst-1s 1
.venv/bin/python probe_burst.py burst-variants-1 1 commentary-plain commentary-framed developer-plain developer-framed
.venv/bin/python exp_a.py a-router-mixed-1 router-mixed      # router-commentary | router-developer | router-mixed
.venv/bin/python exp_b.py b-audio-3-1 3 90                   # 2 | 3 体
```

`a-router-commentary-1` は、`exp_a.py` の最初の版（`router` という名前、Spirit の発言を `commentary` で渡す）で流した。今の `router-commentary` と同じ組み方。

## 確かめていないこと

- 人の声を音声のまま送る形（前の lab の形）を、Spirit 3 体と Spirit どうしの音声と組み合わせたとき
- 話し始めの衝突を減らす仕組み（話している Spirit がいる間はほかの Spirit への音を止める、順番を決める進行役など）
- 端末のスピーカーから出た Spirit の声をマイクが拾う問題（エコー除去）。この lab ではマイクを使っていない
- 4 体以上、90 秒を超える会話
