#!/usr/bin/env python3
"""Prepare lower-level PCM for device-free replay without restoring output gain."""
import argparse,array,hashlib,json,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('output',type=Path);p.add_argument('--scale',type=float,default=.5);a=p.parse_args()
if not 0<a.scale<=1:raise SystemExit('Scale must be >0 and <=1')
if a.output.exists():raise SystemExit('Use a fresh output file; original artifacts are preserved')
data=a.input.read_bytes()
if len(data)%2:raise SystemExit('Expected mono PCM16 little-endian')
x=array.array('h');x.frombytes(data)
if sys.byteorder!='little':x.byteswap()
y=array.array('h',(round(v*a.scale)for v in x))
if sys.byteorder!='little':y.byteswap()
out=y.tobytes();a.output.write_bytes(out)
print(json.dumps({'captureScale':a.scale,'postGain':1,'inputSha256':hashlib.sha256(data).hexdigest(),'scaledInputSha256':hashlib.sha256(out).hexdigest(),'samples':len(x)}))
