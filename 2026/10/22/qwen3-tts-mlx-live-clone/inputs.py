"""Fixed public test asset, cut boundaries, transcripts and synthetic prompts."""
from pathlib import Path
import hashlib
import json
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

REF_TEXT='もしもし、もう駅に着いた？こっちはまだ電車。あと5分くらいかな。助かる。今日は結構寒いね。'
TEXT='こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？'
LONG=TEXT+'帰りに本屋へ寄って、新しい小説も探しましょう。急がなくても大丈夫です。それから、明日の予定も一緒に考えましょう。午後は図書館で少し勉強して、夕方には家に帰るつもりです。'
MODEL='mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16'
REV='a6eb4f68e4b056f1215157bb696209bc82a6db48'

def make_reference(asset, output, short=False):
    digest=hashlib.sha256(Path(asset).read_bytes()).hexdigest()
    if digest!='e671750e8c07ae025096e7184740a9351aed85f42625d56310d6e26b6e5d7e3d':
        raise ValueError('Unexpected shared asset revision; verify its provenance before running')
    data,sr=sf.read(asset,dtype='float32')
    if data.ndim>1: data=data.mean(axis=1)
    # Match the shared asset's known speaker-1 utterance boundaries.
    ranges=[(0.000,1.851),(4.737,7.317),(9.677,11.834)]
    if short: ranges=ranges[:1]
    pieces=[data[round(a*sr):round(b*sr)] for a,b in ranges]
    audio=np.concatenate(pieces)
    audio=resample_poly(audio,24000,sr).astype(np.float32)
    output=Path(output);output.mkdir(exist_ok=True,parents=True)
    path=output/'reference.wav';sf.write(path,audio,24000,subtype='FLOAT')
    meta={'asset':'kiarina/test-assets conversation_2speaker_14s_16k.mp3',
          'asset_sha256':hashlib.sha256(Path(asset).read_bytes()).hexdigest(),
          'ranges_s':ranges,'resample':'scipy.signal.resample_poly to 24000 Hz',
          'samples':len(audio),'wave_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'text':'もしもし、もう駅に着いた？' if short else REF_TEXT}
    (output/'reference.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2))
    return audio,path
