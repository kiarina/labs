import test from 'node:test';
import assert from 'node:assert/strict';
import {VOWELS,normalizeVowels,sampleMouth,clipDuration,MouthPlayback} from './mouth_motion.mjs';
const sum=w=>Object.values(w).reduce((a,b)=>a+b,0);
const near=(a,b)=>assert.ok(Math.abs(a-b)<1e-10,`${a} != ${b}`);

test('external weights remain finite, nonnegative and normalized',()=>{
 for(const input of [null,{}, {aa:-1,ih:NaN,ou:Infinity}, {aa:2,ih:1},
  Object.fromEntries(VOWELS.map(v=>[v,Number.MAX_VALUE]))]){
  const w=normalizeVowels(input);assert.ok(sum(w)<=1+1e-12);
  assert.ok(Object.values(w).every(v=>Number.isFinite(v)&&v>=0));
 }
 near(normalizeVowels({aa:2,ih:1}).aa,2/3);
 near(normalizeVowels({aa:.5},.4).aa,.2);
});
test('full cycles close, visit every vowel and remain continuous at loop boundaries',()=>{
 for(const mode of ['vowels','conversation']){
  const seen=new Set();let previous=sampleMouth(mode,0);
  for(let t=0;t<=clipDuration(mode)*2;t+=5){
   const w=sampleMouth(mode,t);assert.ok(sum(w)<=1+1e-12);
   for(const v of VOWELS){if(w[v]>.1)seen.add(v);assert.ok(Math.abs(w[v]-previous[v])<.1);}
   previous=w;
  }
  assert.equal(seen.size,5);near(sum(sampleMouth(mode,0)),0);
  near(sum(sampleMouth(mode,clipDuration(mode)-1)),0);
  near(sum(sampleMouth(mode,clipDuration(mode))),0);
 }
 const blended=sampleMouth('conversation',240);
 assert.ok(blended.aa>0&&blended.ih>0);
 near(sum(sampleMouth('conversation',1000)),0);
});
test('clock supports pause/resume, speed changes, seeking and stop without jumps',()=>{
 const p=new MouthPlayback();p.play(true,100);p.advance(500);near(p.position,400);
 p.play(false,500);const paused=p.weights();p.advance(5000);assert.deepEqual(p.weights(),paused);
 p.play(true,5000);p.advance(5100);near(p.position,500);
 p.configure({speed:2},5100);p.advance(5200);near(p.position,700);
 p.seek(2750,5200);near(p.position,2750);
 p.select('conversation',5200);near(p.position,0);
 p.reset(5200);assert.equal(p.playing,false);near(sum(p.weights()),0);
 p.advance(6000);near(sum(p.weights()),0);
 assert.equal(p.speed,2); // Stop retains the user's speed preference.
 p.play(true,6000);p.advance(6100);p.advance(6050);p.advance(6120);near(p.position,240);
});
