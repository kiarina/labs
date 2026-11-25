"""Draw the camera frames with codex (built-in image generation, ChatGPT login). base first, then each frame from base with -i.

usage: python make_frames.py base | frames [key ...]   (-j 3 in parallel)
Writes work/frames/<key>.png and frames/<key>.jpg (1280x720) and frames/<key>.json (prompt and codex's report).
"""
import concurrent.futures as cf, json, shutil, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

HERE = Path(__file__).parent
SPEC = json.loads((HERE / 'frames.json').read_text())
RAW, OUT = HERE / 'work' / 'frames', HERE / 'frames'


def prompt(key):
    head = ('あなたは映像の検証用の素材を作るスタッフです。画像生成ツール（gpt-image-2.5）を使って、写真のようにリアルな画像を1枚作ってください。'
            '横長 16:9（1536x864 前後）、ファイル名は out.png。git は使わない。プログラムで画像を加工しない。\n\n')
    if key == 'base':
        body = '場面: ' + SPEC['base']
    else:
        body = ('添付の画像（基準の画像）と同じ部屋・同じカメラの画角・同じ3人（顔・髪型・服装をそのまま）で、次のように変えた瞬間の画像を作ってください。'
                '人物の顔と服、家具、カメラの位置は基準の画像から変えないこと。\n\n変えること: ' + SPEC['frames'][key])
    tail = '\n\n入れないもの: 文字、ロゴ、透かし、画面の枠。\n最後に、ファイル名、使った画像生成のモデル名、条件どおりにできなかった点を短く報告してください。'
    return head + body + tail


def draw(key):
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        p = prompt(key)
        cmd = ['codex', 'exec', '--skip-git-repo-check', '-C', str(d), '-o', str(d / 'report.txt')]
        if key != 'base':
            cmd += ['-i', str(RAW / 'base.png')]
        r = subprocess.run(cmd + ['-'], input=p, text=True, capture_output=True, timeout=600)
        png = d / 'out.png'
        if not png.exists():
            cands = sorted(d.rglob('*.png'))
            png = cands[0] if cands else None
        if not png:
            return key, 'no image: ' + (r.stdout[-300:] + r.stderr[-300:])
        RAW.mkdir(parents=True, exist_ok=True); OUT.mkdir(exist_ok=True)
        shutil.copy(png, RAW / f'{key}.png')
        Image.open(png).convert('RGB').resize((1280, 720), Image.LANCZOS).save(OUT / f'{key}.jpg', quality=85)
        report = (d / 'report.txt').read_text() if (d / 'report.txt').exists() else ''
        (OUT / f'{key}.json').write_text(json.dumps({'key': key, 'prompt': p, 'report': report}, ensure_ascii=False, indent=1) + '\n')
        return key, 'ok'


if __name__ == '__main__':
    if sys.argv[1] == 'base':
        print(draw('base'))
    else:
        keys = sys.argv[2:] or list(SPEC['frames'])
        with cf.ThreadPoolExecutor(3) as ex:
            for k, st in ex.map(draw, keys):
                print(k, st, flush=True)
