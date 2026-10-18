#!/usr/bin/env python3
"""Validate recorded end-to-end evidence, not only callback availability."""
import json,pathlib,sys

def check(path):
    doc=json.loads(path.read_text()); report=doc.get('result',doc)
    errors=[]
    def require(value,message):
        if not value:errors.append(message)
    require(report.get('pass') is True,'app reports failure')
    independent=report.get('receiver')=='independent-chromium'
    expected={'camera':0,'microphone':0 if report.get('synthetic') else 1} if independent else {'camera':1,'microphone':1}
    require(report.get('captureStarts')==expected,'capture start counts differ from the declared sources')
    require([p.get('name') for p in report.get('phases',[])]==['idle-before','send-1','idle-after-1','send-2','idle-after-2'],'missing or reordered phases')
    for phase in report.get('phases',[]):
        name=phase['name']; sending=name.startswith('send-'); seconds=6 if sending else 3
        require(phase.get('sourceVideoFrames',0)>=seconds*5,name+': source video below 5 fps')
        require(phase.get('sourceAudioBytes',0)>=seconds*48000*2*.7,name+': source PCM below 70% of nominal')
        if not sending:
            require(phase.get('injectedAudioBytes')==0 and phase.get('injectedVideoFrames')==0,name+': injected while idle')
            continue
        require(phase.get('injectedAudioBytes',0)>0 and phase.get('injectedVideoFrames',0)>0,name+': no injected source data')
        receiver=phase.get('receiver',{})
        if independent:
            delta=phase.get('receiverDelta',{})
            require(delta.get('videoFramesDecoded',0)>0,name+': no decoded video frames')
            require(delta.get('audioSamples',0)>0,name+': no decoded audio samples')
            require(delta.get('audioRmsMax',0)>(.05 if report.get('synthetic') else 1e-6),name+': zero/insufficient received PCM energy')
            rows=list(phase.get('afterStats',{}).values())
        else:
            require(receiver.get('video',{}).get('videoFrames',0)>0,name+': no decoded video payload')
            require((receiver.get('audio',{}).get('rms') or 0)>1e-6,name+': zero received PCM energy')
            rows=phase.get('inboundStats',[])
        audio=[r for r in rows if r.get('kind',r.get('mediaType'))=='audio']
        video=[r for r in rows if r.get('kind',r.get('mediaType'))=='video']
        require(any(float(r.get('packetsReceived',0))>0 and float(r.get('totalSamplesReceived',0))>0 for r in audio),name+': missing decoded audio RTP samples')
        require(any(float(r.get('framesDecoded',0))>0 for r in video),name+': missing decoded video RTP stats')
    for kind in ['audio','video']:
        require(0<report.get('maxSourceGapMs',{}).get(kind,0)<=500,kind+': source gap >500ms or unavailable')
    return errors

if __name__=='__main__':
    failed=False
    for arg in sys.argv[1:]:
        path=pathlib.Path(arg);errors=check(path)
        print(path.name+': '+('; '.join(errors) if errors else 'PASS (source rates/gaps, idle gate, remote PCM energy and decoded RTP)'))
        failed|=bool(errors)
    raise SystemExit(int(failed))
