"""Waveform-based local-device / reflected-input / session-clock correlation.
PCM stays in RAM. The output clock correspondence is bounded, not assumed exact.
"""
import numpy as np

class AudioClock:
 def __init__(self):
  self.echo=[];self.echo_samples=0;self.references=[];self.clock_pairs=[];self.anchors=[];self.last_reference_end=-1.;self.event_types={}
 def reflected_input(self,pcm24):
  x=np.frombuffer(pcm24,dtype='<i2').astype(np.float64)/32768.;self.echo.append(x);self.echo_samples+=len(x)
 def reflected_output(self,end_ms):
  if self.echo_samples:self.clock_pairs.append(float(end_ms)-self.echo_samples/24.)
 def reference(self,pcm48,device_ms):
  x=np.frombuffer(pcm48,dtype='<i2').astype(np.float64)/32768.;self.references.append((float(device_ms),x))
 @staticmethod
 def match(signal,template):
  # Common 3kHz grid, pre-emphasis and normalized sliding cross correlation.
  signal=np.asarray(signal);template=np.asarray(template)
  if len(signal)<len(template)+10:return None
  signal=signal-np.r_[0,signal[:-1]]*.9;template=template-np.r_[0,template[:-1]]*.9;template-=template.mean();energy=float(template@template)
  if energy<1e-5:return None
  n=1<<(len(signal)+len(template)-1).bit_length();raw=np.fft.irfft(np.fft.rfft(signal,n)*np.fft.rfft(template[::-1],n),n)[len(template)-1:len(signal)]
  sums=np.r_[0,np.cumsum(signal)];squares=np.r_[0,np.cumsum(signal*signal)];m=len(template);denom=np.maximum(squares[m:]-squares[:-m]-(sums[m:]-sums[:-m])**2/m,1e-12)
  scores=raw/np.sqrt(denom*energy);peak=int(np.argmax(scores));best=float(scores[peak]);other=scores.copy();other[max(0,peak-300):min(len(other),peak+301)]=-1;second=float(np.max(other))
  return peak/3.,best,best-second
 def update(self):
  if self.echo_samples<24000 or len(self.references)<4 or not self.clock_pairs:return None
  echo=np.concatenate(self.echo)[::8]
  for end in range(4,len(self.references)+1):
   chosen=self.references[end-4:end];device=chosen[0][0]
   if device<=self.last_reference_end:continue
   if any(abs(b[0]-(a[0]+len(a[1])/48.))>15 for a,b in zip(chosen,chosen[1:])):continue
   template=np.concatenate([x for _,x in chosen])[::16]
   if np.sqrt(np.mean(template*template))<.008:continue
   match=self.match(echo,template)
   if match is None:continue
   echo_ms,score,margin=match
   if score<.65 or margin<.12:continue
   self.anchors.append({'device_ms':device,'echo_ms':echo_ms,'device_minus_echo_ms':device-echo_ms,'correlation':score,'peak_margin':margin});self.last_reference_end=device+750
  if len(self.anchors)<2:return None
  recent=self.anchors[-6:];offsets=np.array([a['device_minus_echo_ms']for a in recent]);center=float(np.median(offsets));residual=float(np.max(np.abs(offsets-center)))
  pairs=np.asarray(self.clock_pairs[-40:]);session_minus_echo=float(np.median(pairs));spread=float(np.percentile(pairs,95)-np.percentile(pairs,5))
  slopes=np.diff([a['device_ms']for a in recent])/np.diff([a['echo_ms']for a in recent])
  regions=[];current=[]
  for anchor in self.anchors:
   if current:
    prior=current[-1];delta=anchor['echo_ms']-prior['echo_ms'];slope=(anchor['device_ms']-prior['device_ms'])/delta if delta>0 else 0
    if delta>4000 or not .9<=slope<=1.1 or abs(anchor['device_minus_echo_ms']-prior['device_minus_echo_ms'])>100:
     if len(current)>=2:regions.append(current)
     current=[]
   current.append(anchor)
  if len(current)>=2:regions.append(current)
  valid=bool(regions) and spread<=250
  region_residual=max((max(abs(a['device_minus_echo_ms']-np.median([b['device_minus_echo_ms']for b in region]))for a in region)for region in regions),default=residual)
  return {'valid':bool(valid),'method':'waveform_echo_segmented_with_output_clock_bound','offset_ms':center-session_minus_echo,'uncertainty_ms':max(10.,region_residual+spread/2+100),'anchor_count':len(self.anchors),'max_waveform_residual_ms':residual,'output_clock_spread_ms':spread,'max_local_slope_deviation':float(np.max(np.abs(slopes-1))),'session_minus_echo_ms':session_minus_echo,'minimum_correlation':min(a['correlation']for a in recent),'anchors':self.anchors.copy(),'supported_regions':[{'start_echo_ms':region[0]['echo_ms'],'end_echo_ms':region[-1]['echo_ms'],'anchors':len(region)}for region in regions]}
 def summary(self):return {'reflected_input_samples':self.echo_samples,'clock_pair_count':len(self.clock_pairs),'anchors':self.anchors,'alignment':self.update()}
