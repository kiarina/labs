import {VOWELS,normalizeVowels} from './mouth_motion.mjs';

export function validateAudioManifest(m){
 if(m?.version!==1||!Number.isFinite(m.duration)||m.duration<=0||m.duration>120)throw Error('Invalid audio duration/version');
 if(!/^[a-f0-9]{64}$/.test(m.audioSha256))throw Error('Missing audio fingerprint');
 if(!Array.isArray(m.cues)||!m.cues.length)throw Error('Missing vowel cues');
 let previous=0;
 for(const c of m.cues){
  if(!VOWELS.includes(c.vowel)||!Number.isFinite(c.start)||!Number.isFinite(c.end)||c.start<previous||c.end<=c.start||c.end>m.duration)throw Error('Invalid vowel cue');
  previous=c.end;
 }
 const e=m.envelope;
 if(!e||!Number.isFinite(e.step)||e.step<=0||e.step>.1||!Number.isFinite(e.origin)||e.origin<0||e.origin>e.step||!Array.isArray(e.values)||!e.values.length||e.values.some(v=>!Number.isFinite(v)||v<0||v>1)||e.origin+(e.values.length-1)*e.step<m.duration-e.step)throw Error('Invalid audio envelope');
 return m;
}
export function sampleAudioMouth(manifest,seconds,amount=1){
 if(!Number.isFinite(seconds)||seconds<0||seconds>=manifest.duration)return normalizeVowels();
 const cue=manifest.cues.find(c=>seconds>=c.start&&seconds<c.end);
 if(!cue)return normalizeVowels();
 const e=manifest.envelope,index=Math.max(0,Math.min(e.values.length-1,(seconds-e.origin)/e.step));
 const left=Math.floor(index),right=Math.min(left+1,e.values.length-1),fraction=index-left;
 return normalizeVowels({[cue.vowel]:e.values[left]*(1-fraction)+e.values[right]*fraction},amount);
}

// currentTime is the only clock. There is no independently advancing mouth timer.
export class AudioMouthPlayback{
 constructor(media,manifest){this.media=media;this.manifest=validateAudioManifest(manifest);this.amount=.8;}
 get playing(){return !this.media.paused&&!this.media.ended;}
 get position(){return this.media.currentTime*1000;}
 get duration(){return this.manifest.duration*1000;}
 weights(){return this.media.error||this.media.ended?normalizeVowels():sampleAudioMouth(this.manifest,this.media.currentTime,this.amount);}
 async play(){if(this.media.ended)this.media.currentTime=0;await this.media.play();}
 pause(){this.media.pause();}
 reset(){this.media.pause();this.media.currentTime=0;return normalizeVowels();}
 seek(ms){if(Number.isFinite(ms))this.media.currentTime=Math.max(0,Math.min(this.manifest.duration,ms/1000));return this.weights();}
 configure({speed=this.media.playbackRate,amount=this.amount}){
  if(Number.isFinite(speed))this.media.playbackRate=Math.max(.25,Math.min(2,speed));
  if(Number.isFinite(amount))this.amount=Math.max(0,Math.min(1,amount));
  return this.weights();
 }
}
