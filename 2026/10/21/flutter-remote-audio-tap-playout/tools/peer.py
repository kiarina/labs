#!/usr/bin/env python3
"""Lab far-speech sender and silent clean-near receiver; private PCM stays local."""
import argparse
import asyncio
from fractions import Fraction
import json
from pathlib import Path
import time
import numpy as np
from aiohttp import web
from aiortc import RTCPeerConnection, RTCConfiguration, RTCSessionDescription, MediaStreamTrack
from av import AudioFrame, AudioResampler

p=argparse.ArgumentParser();p.add_argument('--speech',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--port',type=int,default=18794);p.add_argument('--far-gain',type=float,default=1.0);p.add_argument('--host',default='127.0.0.1');a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
speech=np.frombuffer(a.speech.read_bytes(),dtype='<i2');far_enabled=False;phase='idle';connections=[];tasks=set();samples=0;video_frames=0;phases=[];received=None;session=None
class Far(MediaStreamTrack):
    kind='audio'
    def __init__(self):super().__init__();self.index=0;self.start=None;self.pts=0
    async def recv(self):
        if self.start is None:self.start=time.monotonic()
        await asyncio.sleep(max(0,self.start+self.pts/48000-time.monotonic()))
        values=np.zeros(960,dtype=np.int16)
        if far_enabled:
            indices=(np.arange(960)+self.index)%len(speech);values=np.clip((speech[indices].astype(np.float64)*a.far_gain).astype(np.int32),-27000,27000).astype(np.int16);self.index+=960
        frame=AudioFrame(format='s16',layout='mono',samples=960);frame.planes[0].update(values.tobytes());frame.sample_rate=48000;frame.pts=self.pts;frame.time_base=Fraction(1,48000);self.pts+=960;return frame
async def consume(track):
    global samples,video_frames
    converter=AudioResampler(format='s16',layout='mono',rate=48000)
    try:
        while True:
            frame=await track.recv()
            if track.kind=='audio':
                for converted in converter.resample(frame):
                    data=converted.to_ndarray().astype('<i2').tobytes();received.write(data);samples+=len(data)//2
            else:video_frames+=1
    except Exception as e:
        print(json.dumps({'track':track.kind,'ended':type(e).__name__}),flush=True)
async def offer(request):
    global received,samples,video_frames,session,far_enabled,phase,phases
    body=await request.json();name=body['session'];assert name.replace('-','').replace('_','').isalnum()
    await close_all();session=name;samples=video_frames=0;far_enabled=False;phase='quiet';phases=[]
    received=(a.output/(name+'-received.pcm')).open('wb')
    pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));connections.append(pc)
    @pc.on('track')
    def on_track(track):
        task=asyncio.create_task(consume(track));tasks.add(task);task.add_done_callback(tasks.discard)
    await pc.setRemoteDescription(RTCSessionDescription(sdp=body['sdp'],type=body['type']))
    pc.addTrack(Far());await pc.setLocalDescription(await pc.createAnswer())
    return web.json_response({'sdp':pc.localDescription.sdp,'type':pc.localDescription.type})
async def state(request):
    global far_enabled,phase
    body=await request.json();far_enabled=bool(body['far']);phase=body['phase'];phases.append({'phase':phase,'far':far_enabled,'samples':samples,'videoFrames':video_frames,'utcMs':time.time()*1000})
    if received:received.flush()
    return web.json_response({'samples':samples,'videoFrames':video_frames})
async def stats(request):return web.json_response({'samples':samples,'videoFrames':video_frames,'phase':phase,'far':far_enabled})
async def close_all():
    global received
    for pc in connections:await pc.close()
    connections.clear()
    for task in list(tasks):task.cancel()
    if received:received.close();received=None
async def finish(request):
    if received:received.flush()
    report={'session':session,'samples':samples,'videoFrames':video_frames,'phases':phases,'receiverPlayback':False}
    (a.output/(session+'-peer.json')).write_text(json.dumps(report,indent=2)+'\n');await close_all();return web.json_response(report)
async def cleanup(app):await close_all()
app=web.Application();app.router.add_post('/offer',offer);app.router.add_post('/state',state);app.router.add_get('/stats',stats);app.router.add_post('/finish',finish);app.on_cleanup.append(cleanup)
web.run_app(app,host=a.host,port=a.port)
