#!/usr/bin/env python3
"""The third voice is an explicitly synthetic local negative-control fixture."""
import subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
subprocess.run(['/usr/bin/say','-v','Samantha','-r','175','-o',str(root/'work/refine-third.aiff'),'This is a different speaker for a laboratory test. The weather is pleasant today and I am going for a walk.'],check=True)
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(root/'work/refine-third.aiff'),'-ar','16000','-ac','1','-c:a','pcm_s16le',str(root/'asr/app/assets/refine-third.wav')],check=True)
