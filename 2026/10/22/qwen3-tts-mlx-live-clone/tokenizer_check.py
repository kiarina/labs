import json
import random
from pathlib import Path
from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
from live import TextSource

MODEL='mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16'
REV='a6eb4f68e4b056f1215157bb696209bc82a6db48'
def check(tokenizer):
    texts=['こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？',
           '「少し」待って……。2026年10月22日、MLXでTTSを試す！\n次の文です。',
           "Hello, don't stop. I'm testing Japanese: 駅前で coffee を飲む。  OK?",
           'これは句読点なしの長い日本語入力でも勝手な空白を足さずに処理できるか調べる文章です',
           'おはよう\n\nございます。😀ありがとうございます！']
    outcomes=[]
    for text in texts:
        expected=tokenizer.encode(text,add_special_tokens=False)
        for seed in range(20):
            rng=random.Random(seed);source=TextSource(tokenizer);offset=0;polls=[]
            while offset<len(text):
                size=1 if seed==0 else rng.randint(1,8)
                source.push(text[offset:offset+size]);offset+=size
                ids,_,_=source.poll();assert expected[:len(ids)]==ids
                polls.append(len(ids))
            source.close();ids,closed,_=source.poll();assert ids==expected and closed
            outcomes.append({'text':text,'seed':seed,'token_count':len(ids),'commit_counts':polls})
    return outcomes
def check_lifecycle(tokenizer):
    import threading
    import time
    source=TextSource(tokenizer);source.push('こんにちは。');source.close()
    try: source.push('追加')
    except RuntimeError: pass
    else: raise AssertionError('Push after close must be rejected')
    cancelled=TextSource(tokenizer);version=cancelled.poll()[2];woke=threading.Event()
    thread=threading.Thread(target=lambda:(cancelled.wait(version),woke.set()))
    thread.start();cancelled.cancel();thread.join(1)
    assert woke.is_set() and not thread.is_alive()
    try: cancelled.poll()
    except InterruptedError: pass
    else: raise AssertionError('Cancellation must be explicit')
    idle=TextSource(tokenizer);version=idle.poll()[2]
    try: idle.wait(version,timeout=.001)
    except TimeoutError: pass
    else: raise AssertionError('Idle must raise, not silently end the utterance')
    assert not idle.closed
    return {'push_after_close_rejected':True,'cancel_wakes_waiter':True,'idle_timeout_is_error_not_eos':True}

if __name__=='__main__':
    tokenizer=AutoTokenizer.from_pretrained(snapshot_download(MODEL,revision=REV))
    result=check(tokenizer);Path('output').mkdir(exist_ok=True)
    Path('output/tokenizer-check.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    Path('output/lifecycle-check.json').write_text(json.dumps(check_lifecycle(tokenizer),indent=2))
    print('Exact prefix/final token parity:',len(result),'fragmentation cases')
