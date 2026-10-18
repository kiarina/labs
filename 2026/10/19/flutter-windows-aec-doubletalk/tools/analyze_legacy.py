#!/usr/bin/env python3
"""Read local legacy PCM; emit metrics only. Requires numpy/scipy."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from scipy import signal

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('artifacts', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
r = a.artifacts
report = json.loads((r / 'report.json').read_text())
rate = 48000
pcm = {n: np.fromfile(r / (n + '.pcm'), dtype='<i2').astype(float)
       for n in ['raw', 'mixed', 'clean', 'near', 'reference', 'actual_render']}

def db(x):
    return float(20 * np.log10(max(abs(x), 1e-15)))

def rms(x):
    return float(np.sqrt(np.mean(x*x)))

def peak_lag(y, x, begin, radius=24000):
    # Local reference slice avoids allowing an unrelated phase to win.
    left = max(0, begin-radius)
    right = min(len(x), begin+len(y)+radius)
    ref = x[left:right]
    c = signal.correlate(y, ref, method='fft')
    lag = signal.correlation_lags(len(y), len(ref)) + begin-left
    mask = abs(lag) <= radius
    k = np.flatnonzero(mask)[np.argmax(abs(c[mask]))]
    d = int(lag[k])
    idx = np.arange(begin, begin+len(y))-d
    ok = (idx >= 0) & (idx < len(x))
    xx, yy = x[idx[ok]], y[ok]
    corr = float(np.dot(xx, yy) / max(np.linalg.norm(xx)*np.linalg.norm(yy), 1e-15))
    return d, corr

bands = [(80, 330), (330, 680), (680, 725), (725, 2500),
         (2500, 8000), (8000, 16000), (16000, 23900)]
rows = []
near_lag = None
for phase in report['phases']:
    begin = phase['start']['rawByte']//2 + rate
    end = phase['end']['rawByte']//2
    raw, clean = pcm['raw'][begin:end], pcm['clean'][begin:end]
    row = {'name': phase['name'], 'samples': len(raw),
           'rawRmsDbfs': db(rms(raw)/32768),
           'cleanRmsDbfs': db(rms(clean)/32768),
           'rawClippedFraction': float(np.mean(abs(raw) >= 32700))}
    if phase.get('digitalNearEnd'):
        near = pcm['near'][begin:end]
        if near_lag is None:
            near_lag, _ = peak_lag(clean, pcm['near'], begin, 4800)
        idx = np.arange(begin, end)-near_lag
        ok = (idx >= 0) & (idx < len(pcm['near']))
        x, y = pcm['near'][idx[ok]], clean[ok]
        gain = float(np.dot(x, y)/max(np.dot(x, x), 1e-15))
        row['near'] = {'lagSamples': near_lag, 'signedGain': gain,
                       'gainDb': db(gain), 'correlation': float(np.dot(x,y)/max(np.linalg.norm(x)*np.linalg.norm(y),1e-15))}
    if phase.get('speakerSignal'):
        lag, corr = peak_lag(raw, pcm['actual_render'], begin)
        row['wholePhasePeak'] = {'lagSamples': lag, 'correlation': corr}
        row['oneSecondPeaks'] = []
        for start in range(begin, end-rate+1, rate):
            d, c = peak_lag(pcm['raw'][start:start+rate], pcm['actual_render'], start)
            row['oneSecondPeaks'].append({'captureSecond': start/rate, 'lagSamples': d,
                                         'correlation': c, 'atSearchBoundary': abs(d) == 24000})
        # Coherence reports a frequency-dependent relation, not scalar echo energy.
        idx = np.arange(begin,end)-lag
        ok = (idx>=0)&(idx<len(pcm['actual_render']))
        x, y = pcm['actual_render'][idx[ok]], raw[ok]
        f, coh = signal.coherence(x,y,fs=rate,nperseg=4096)
        _, ps = signal.welch(y,fs=rate,nperseg=4096)
        _, px = signal.welch(x,fs=rate,nperseg=4096)
        row['bands'] = []
        for low, high in bands:
            m = (f>=low)&(f<high)
            row['bands'].append({'lowHz': low,'highHz':high,
                'medianCoherence':float(np.median(coh[m])),
                'referenceWeightedCoherence':float(np.sum(coh[m]*px[m])/max(np.sum(px[m]),1e-15)),
                'rawPowerFraction':float(np.sum(ps[m])/max(np.sum(ps),1e-15))})
        k=np.argsort(ps)[-8:][::-1]
        row['rawSpectralPeaksHz']=[float(f[i]) for i in k]
    rows.append(row)

# The queued reference index equals generator sample counter, including silence.
f,t,z = signal.stft(pcm['reference'],fs=rate,nperseg=1024,noverlap=768)
energy=abs(z)**2
excited=(np.sum(energy,axis=0)>1e4)
exclude=(f<150)|(abs(f-701)<140)
energy[exclude,:]=0
peak=f[np.argmax(energy,axis=0)]
k=np.floor(.71*t)
instant=330+3124*t-2200*k
folded=abs((instant+rate/2)%rate-rate/2)
# Exclude sawtooth reset windows, spectral boundary and nearly silent frames.
valid=excited&(abs((.71*t)%1-.5)<.46)&(folded>900)&(folded<23000)
errors=abs(peak[valid]-folded[valid])
examples=[]
for target in [10,16,22,28,34]:
    candidates=np.flatnonzero(valid & (abs(t-target)<.5))
    if len(candidates):
        j=int(candidates[np.argmin(abs(t[candidates]-target))])
        examples.append({'timeSeconds':float(t[j]),'nominalFHz':float(330+2200*((.71*t[j])%1)),
                         'instantaneousUnfoldedHz':float(instant[j]),'predictedAliasedHz':float(folded[j]),
                         'observedPeakExcluding701Hz':float(peak[j])})
out={'source':'legacy Windows local PCM; no new playback or DSP replay',
     'limitations':['Coherence and scalar projection are not all-echo energy or ERLE.',
                    'One-second lag aliases can reflect the old periodic stimulus and low SNR, not solely clock drift.',
                    'Known digital near retention does not establish human speech quality.'],
     'sampleRate':rate,'phaseDiagnostics':rows,
     'legacyStimulus':{'phaseRadians':'2*pi*t*(330+2200*frac(.71*t))',
       'instantaneousHzAwayFromResets':'330+3124*t-2200*floor(.71*t)',
       'resetPeriodSeconds':1/.71,'resetPhaseJumpCycles':'-2200*t at each reset',
       'foldToNyquist':'abs((instantaneousHz+24000)%48000-24000)',
       'spectralFramesCompared':int(np.sum(valid)),
       'medianPeakPredictionErrorHz':float(np.median(errors)),
       'fractionWithin150Hz':float(np.mean(errors<150)),
       'referenceEnergyAbove2500HzFraction':float(np.sum(abs(z[f>2500,:])**2)/np.sum(abs(z)**2)),
       'examples':examples},
     'artifactsSha256':{n+'.pcm':hashlib.sha256((r/(n+'.pcm')).read_bytes()).hexdigest() for n in pcm}}
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out['legacyStimulus'],indent=2))
