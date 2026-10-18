// Digital verification only: no microphone, speakers or browser acoustic path.
import createModule from '../../app/web/aec_engine.js';
const m=await createModule();
const input=m._malloc(960),output=m._malloc(960);
function processFrame(handle,far,mic,delay=80){
  m.HEAP16.set(far,input>>1);let rc=m._aec_reverse(handle,input,480);
  if(rc!==0)throw Error('reverse '+rc);
  m.HEAP16.set(mic,input>>1);rc=m._aec_capture(handle,input,output,480,delay);
  if(rc!==0)throw Error('capture '+rc);
  return m.HEAP16.slice(output>>1,(output>>1)+480);
}
let seed=123456789;const random=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return (seed>>>0)/4294967296*2-1;};
const rate=48000,length=rate*18,delay=rate*0.08;
const far=new Int16Array(length),near=new Int16Array(length),mic=new Int16Array(length);
let filteredFar=0,filteredNear=0;
for(let i=0;i<length;i++){
  filteredFar=0.8*filteredFar+0.2*random();filteredNear=0.75*filteredNear+0.25*random();
  far[i]=Math.round(filteredFar*13000*(0.65+0.35*Math.sin(i/rate*6)));
  near[i]=Math.round(filteredNear*9000*(0.6+0.4*Math.sin(i/rate*9)));
}
function scenario(name,echo,local){
  const handle=m._aec_create(1);if(!handle)throw Error('create');
  const clean=new Int16Array(length);
  for(let i=0;i<length;i++)mic[i]=Math.round((echo&&i>=delay?0.5*far[i-delay]:0)+(local?near[i]:0));
  for(let offset=0;offset<length;offset+=480)clean.set(processFrame(handle,echo?far.subarray(offset,offset+480):new Int16Array(480),mic.subarray(offset,offset+480)),offset);
  m._aec_destroy(handle);
  const start=length-rate*3;let inPower=0,outPower=0;
  for(let i=start;i<length;i++){inPower+=mic[i]**2;outPower+=clean[i]**2;}
  // Account for fixed processing delay when measuring known local speech retention.
  let best={correlation:0,lag:0,gain:0};
  if(local)for(let lag=0;lag<=960;lag++){let xy=0,xx=0,yy=0;
    for(let i=start+lag;i<length;i++){const x=near[i-lag],y=clean[i];xy+=x*y;xx+=x*x;yy+=y*y;}
    const correlation=xy/Math.sqrt(xx*yy);if(correlation>best.correlation)best={correlation,lag,gain:xy/xx};}
  let echoGain=null,echoImprovementDb=null;
  if(echo&&local){let xy=0,xx=0;for(let i=start+best.lag+delay;i<length;i++){const x=far[i-best.lag-delay],y=clean[i]-best.gain*near[i-best.lag];xy+=x*y;xx+=x*x;}echoGain=xy/xx;echoImprovementDb=20*Math.log10(0.5/Math.max(Math.abs(echoGain),1e-12));}
  return {name,echoGain,echoImprovementDb,inputRms:Math.sqrt(inPower/(length-start)),outputRms:Math.sqrt(outPower/(length-start)),erleDb:10*Math.log10(inPower/Math.max(outPower,1)),...best};
}
const farOnly=scenario('far-only',true,false),nearOnly=scenario('near-only',false,true),doubleTalk=scenario('double-talk',true,true);
const checks={farOnlyReduction:farOnly.erleDb>=15,nearOnlyPreserved:nearOnly.correlation>=0.95&&Math.abs(20*Math.log10(nearOnly.gain))<=3,doubleTalkPreserved:doubleTalk.gain>=Math.pow(10,-6/20)&&doubleTalk.echoImprovementDb>=6};
const result={done:true,kind:'digital-aec3-wasm',acousticValidated:false,seed:123456789,sampleRate:rate,seconds:length/rate,echoDelayMs:80,echoGain:0.5,farOnly,nearOnly,doubleTalk,checks,pass:Object.values(checks).every(Boolean)};
m._free(input);m._free(output);
if(typeof window!=='undefined')window.result=result;
else {console.log(JSON.stringify(result,null,2));process.exitCode=result.pass?0:1;}
