"""Compare the first 0.5 s of MLX streaming output with non-streaming output, with and without priming the decoder.

Run against the running web UI (`mise run`), from the lab directory:
    uv run python bench/streaming_onset/compare.py
Uses the first reference (sample speaker 1) and the 7 example sentences of the web UI. Only pairs whose length
matches are compared (a different length means the generated tokens differ, not the decoding).
"""

import json, urllib.request, numpy as np, soundfile as sf
B = "http://127.0.0.1:8776"
OUT = "output/webui/"
ref=json.load(urllib.request.urlopen(B+"/api/references"))[0]["id"]
texts=["こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？","ちょっと待って。チケットはもう買ってあるから、ゆっくり行こうよ。","明日の朝、七時三十分に、東京駅の八重洲口で待ち合わせしましょう。","えっ、本当に？すごい！ずっと楽しみにしてたんだ、ありがとう！","この機能を使うには、設定の画面を開いて、スピーカーで話すをオンにしてください。","MacBook の Bluetooth をオフにしてから、もう一度 iPhone とつないでみて。","昔々、ある山のふもとに、小さな村がありました。村の人たちは毎朝、川で水をくみ、畑を耕して、静かに暮らしていました。"]
cols=["mlx-bf16","mlx-8bit","mlx-4bit"]
def call(text, stream, prime=True, k=0):
    body=json.dumps({"text":text,"reference_id":ref,"columns":cols,"stream":stream,"streaming_interval":0.5,"prime_decoder":prime,"prime_tokens":k,"sequential":True}).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(B+"/api/synthesize",data=body,method="POST")))["results"]
def load(r): return sf.read(OUT+r["url"].split("/")[-1], dtype="float32")[0]
settings=[("none",False,0),("12",True,12),("25",True,25),("50",True,50),("all",True,0)]
stats={(c,s[0]):{"corr":[], "fa":[]} for c in cols for s in settings}
for t in texts:
    base={r["column"]:load(r) for r in call(t,False)}
    for name,p,k in settings:
        for r in call(t,True,p,k):
            x=base[r["column"]]; y=load(r); w=12000
            stats[(r["column"],name)]["fa"].append(r["first_audio_seconds"])
            if len(x)==len(y): stats[(r["column"],name)]["corr"].append(float(np.corrcoef(x[:w],y[:w])[0,1]))
for (c,name),v in stats.items():
    cr=v["corr"]
    print(f"{c:9s} prime={name:4s} same_len={len(cr)}/7 corr_first0.5s min={min(cr) if cr else float('nan'):.3f} mean={np.mean(cr) if cr else float('nan'):.3f} first_audio mean={np.mean(v['fa']):.2f} max={max(v['fa']):.2f}")
