import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
let Meter;
const messages=[];
class Processor {constructor(){this.port={postMessage:x=>messages.push(x)}}}
vm.runInNewContext(fs.readFileSync(new URL('mic_web/meter.js',import.meta.url),'utf8'),{AudioWorkletProcessor:Processor,sampleRate:8,registerProcessor:(name,cls)=>{assert.equal(name,'meter');Meter=cls;}});
const m=new Meter();
m.process([[new Float32Array(4)]],[]);assert.equal(messages.at(-1).nonzero,0);assert.equal(messages.at(-1).rms,0);
m.process([[new Float32Array([.5,-.5,.5,-.5])]],[]);assert.equal(messages.at(-1).samples,8);assert.equal(messages.at(-1).nonzero,4);assert.equal(messages.at(-1).peak,.5);assert.equal(messages.at(-1).maxRms,.5);assert.equal(messages.at(-1).activeSeconds,.5);
m.port.onmessage();m.process([[new Float32Array(4)]],[]);assert.equal(messages.at(-1).samples,4);assert.equal(messages.at(-1).peak,0);
console.log('Worklet meter: silence, nonzero PCM, elapsed active samples and reset passed');
