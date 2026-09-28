import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {AudioMouthPlayback,sampleAudioMouth,validateAudioManifest} from './audio_mouth.mjs';
const manifest=JSON.parse(fs.readFileSync(new URL('../artifacts/vowel-audio/manifest.json',import.meta.url)));
const sum=w=>Object.values(w).reduce((a,b)=>a+b,0);
test('known cues gate measured energy, and silence closes all vowels',()=>{
 validateAudioManifest(manifest);
 for(let t=0;t<manifest.duration;t+=.003){
  const w=sampleAudioMouth(manifest,t,.8),cue=manifest.cues.find(c=>t>=c.start&&t<c.end);
  assert.ok(sum(w)<=.8+1e-10&&Object.values(w).every(v=>v>=0));
  for(const [v,x] of Object.entries(w))if(v!==cue?.vowel)assert.equal(x,0);
 }
 for(const t of [-1,NaN,Infinity,manifest.duration,0])assert.equal(sum(sampleAudioMouth(manifest,t)),0);
 for(const cue of manifest.cues)assert.ok(Array.from({length:100},(_,i)=>sum(sampleAudioMouth(manifest,cue.start+(cue.end-cue.start)*i/100))).some(x=>x>.5));
 for(const change of [{duration:NaN},{cues:[{vowel:'aa',start:-1,end:1}]},{audioSha256:'wrong'},{envelope:{step:.01,origin:0,values:[2]}}])assert.throws(()=>validateAudioManifest({...manifest,...change}));
});
test('media time controls pose across pause, seek, rate and restart',async()=>{
 const media={currentTime:0,paused:true,ended:false,error:null,playbackRate:1,async play(){this.paused=false;},pause(){this.paused=true;}};
 const player=new AudioMouthPlayback(media,manifest);
 player.seek(450);assert.deepEqual(player.weights(),sampleAudioMouth(manifest,.45,.8));
 await player.play();assert.equal(player.playing,true);
 player.pause();const frozen=player.weights();player.configure({speed:1.5});assert.deepEqual(player.weights(),frozen);
 media.currentTime=1.1;assert.deepEqual(player.weights(),sampleAudioMouth(manifest,1.1,.8));
 media.ended=true;assert.equal(sum(player.weights()),0);await player.play();assert.equal(media.currentTime,0);
 media.ended=false;player.seek(500);media.error={};assert.equal(sum(player.weights()),0);
 assert.equal(sum(player.reset()),0);assert.equal(media.currentTime,0);assert.equal(media.paused,true);
});
