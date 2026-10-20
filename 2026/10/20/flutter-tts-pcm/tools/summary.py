#!/usr/bin/env python3
"""Print the main numbers of results/<name>.json (or the given files)."""
import json
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent

for p in [Path(a) for a in sys.argv[1:]] or sorted((LAB / "results").glob("*.json")):
    d = json.loads(p.read_text())
    print(f"## {p.stem}: {d.get('voiceCount')} voices ({d.get('voicesMs')} ms), "
          f"ja {[v['name'] for v in d.get('jaVoices', [])]}, en {d.get('enVoiceCount')}")
    for r in d.get("runs", []):
        a = r.get("asr") or {}
        print(f"  {r['text']} #{r['attempt']}: first {r['firstChunkMs']} ms, total {r['totalMs']} ms, "
              f"audio {r['audioMs']} ms, chunks {r['chunks']}, {r.get('nativeFormat')}, "
              f"lead {r.get('leadingSilenceMs')} ms, peak {r.get('peakDbfs') and round(r['peakDbfs'], 1)} dBFS"
              + (f", CER {a.get('cer'):.3f} '{a.get('text')}'" if 'cer' in a else (f", asr {a}" if a else ""))
              + (f" ERROR {r['error']}" if 'error' in r else ""))
    for r in d.get("jaPerVoice", []):
        a = r.get("asr") or {}
        print(f"  voice {r['voice']} ({r['quality']}): first {r['firstChunkMs']} total {r['totalMs']} "
              f"audio {r['audioMs']} {r.get('nativeFormat')} CER {a.get('cer')}"
              + (f" ERROR {r['error']}" if 'error' in r else ""))
    c = d.get("cancel", {})
    n = c.get("nextRequest", {})
    print(f"  cancel: late chunks {c.get('chunksAfterCancel')}, next ok {n.get('audioMs')} ms audio"
          + (f" ERROR {c['error']}" if 'error' in c else "") + (f" next ERROR {n['error']}" if 'error' in n else ""))
    print("  concurrent: " + ", ".join(f"{x.get('audioMs')} ms audio in {x.get('totalMs')} ms" + (f" ERROR {x['error']}" if 'error' in x else "") for x in d.get("concurrent", [])))
