import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {sampleAudioMouth,validateAudioManifest} from './audio_mouth.mjs';
const sum=w=>Object.values(w).reduce((a,b)=>a+b,0);
const greeting=JSON.parse(fs.readFileSync(new URL('../artifacts/speech-greeting/manifest.json',import.meta.url)));
test('continuous sentence blends adjacent shapes, closes gaps and suppresses final su',()=>{
 validateAudioManifest(greeting);
 let previous=sampleAudioMouth(greeting,0,.8),maxStep=0;
 for(let t=.001;t<greeting.duration;t+=.001){
  const w=sampleAudioMouth(greeting,t,.8);assert.ok(sum(w)<=.8+1e-10);
  for(const v of Object.keys(w))maxStep=Math.max(maxStep,Math.abs(w[v]-previous[v]));previous=w;
 }
 assert.ok(maxStep<.05,`1 ms change ${maxStep}`);
 const lead=.34997732426303857;
 assert.equal(sum(sampleAudioMouth(greeting,lead+.95)),0);
 assert.equal(sum(sampleAudioMouth(greeting,lead+.265)),0);
 const blend=sampleAudioMouth(greeting,lead+1.29);assert.ok(blend.ih>0&&blend.ee>0);
 for(let t=lead+1.84;t<greeting.duration;t+=.01)assert.ok(sum(sampleAudioMouth(greeting,t))<=.2+1e-10);
 assert.throws(()=>validateAudioManifest({...greeting,transitionSeconds:NaN}));
 assert.throws(()=>validateAudioManifest({...greeting,cues:[{...greeting.cues[0],gain:2}]}));
});
