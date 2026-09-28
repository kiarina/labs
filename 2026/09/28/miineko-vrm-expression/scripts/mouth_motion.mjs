// Deterministic, silent authoring previews. These are not audio/phoneme inference.
export const VOWELS=Object.freeze(['aa','ih','ou','ee','oh']);
export const VOWEL_LABELS=Object.freeze({aa:'あ',ih:'い',ou:'う',ee:'え',oh:'お'});
const clamp=(x,min,max)=>Number.isFinite(x)?Math.min(max,Math.max(min,x)):min;

export function normalizeVowels(input={},amount=1){
 const values=VOWELS.map(v=>Number.isFinite(input?.[v])?Math.max(0,input[v]):0);
 // Scale before summing so even very large external weights cannot overflow.
 const scale=Math.max(1,...values),scaled=values.map(v=>v/scale);
 const sum=scaled.reduce((a,b)=>a+b,0),denominator=scale>1?sum:Math.max(1,sum);
 const amplitude=clamp(amount,0,1);
 return Object.fromEntries(VOWELS.map((v,i)=>[v,denominator?scaled[i]/denominator*amplitude:0]));
}
const point=(t,v=null,w=0)=>({t,weights:v?{[v]:w}:{}});
const vowelFrames=[point(0)];
for(let i=0;i<VOWELS.length;i++){
 const t=i*1000,v=VOWELS[i];
 vowelFrames.push(point(t+100),point(t+260,v,1),point(t+650,v,1),point(t+850));
}
vowelFrames.push(point(5500));
const conversationFrames=[point(0),point(180,'aa',.65),point(300,'ih',.5),
 point(440,'ou',.75),point(590,'ee',.6),point(740,'oh',.7),point(920),point(1200),
 point(1370,'ih',.65),point(1540,'ee',.7),point(1750,'aa',.9),point(1930,'ou',.5),
 point(2130),point(2520),point(2690,'oh',.7),point(2890,'aa',.8),
 point(3070,'ee',.6),point(3220,'ih',.45),point(3400),point(4100)];
const clips={vowels:vowelFrames,conversation:conversationFrames};
export function clipDuration(mode){
 if(!clips[mode])throw new RangeError(`Unknown mouth preview: ${mode}`);
 return clips[mode].at(-1).t;
}
export function sampleMouth(mode,elapsed,amount=1){
 const frames=clips[mode];const duration=clipDuration(mode);
 const t=Number.isFinite(elapsed)?((elapsed%duration)+duration)%duration:0;
 let right=1;while(right<frames.length-1&&frames[right].t<t)right++;
 const a=frames[right-1],b=frames[right],u=(t-a.t)/(b.t-a.t),ease=u*u*(3-2*u);
 const weights=Object.fromEntries(VOWELS.map(v=>[v,(a.weights[v]||0)*(1-ease)+(b.weights[v]||0)*ease]));
 return normalizeVowels(weights,amount);
}

export class MouthPlayback{
 constructor(){this.mode='vowels';this.position=0;this.speed=1;this.amount=.8;this.playing=false;this.lastTime=null;}
 advance(now){
  if(!Number.isFinite(now))return this.weights();
  if(this.lastTime!==null&&now<this.lastTime)return this.weights();
  if(this.playing&&this.lastTime!==null&&now>=this.lastTime){
   this.position=(this.position+(now-this.lastTime)*this.speed)%clipDuration(this.mode);
  }
  this.lastTime=now;return this.weights();
 }
 weights(){return sampleMouth(this.mode,this.position,this.amount);}
 play(value,now){this.advance(now);this.playing=Boolean(value);return this.weights();}
 reset(now){this.playing=false;this.position=0;this.lastTime=now;return this.weights();}
 select(mode,now){clipDuration(mode);this.mode=mode;this.position=0;this.lastTime=now;return this.weights();}
 seek(ms,now){this.position=clamp(ms,0,clipDuration(this.mode));this.lastTime=now;return this.weights();}
 configure({speed=this.speed,amount=this.amount},now){
  this.advance(now);this.speed=clamp(speed,.25,2);this.amount=clamp(amount,0,1);return this.weights();
 }
}
