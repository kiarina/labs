class Meter extends AudioWorkletProcessor {
 constructor(){super();this.reset();this.port.onmessage=()=>this.reset();}
 reset(){this.samples=0;this.nonzero=0;this.peak=0;this.maxRms=0;this.activeSamples=0;this.tick=0;}
 process(inputs,outputs){let channels=inputs[0]||[];if(channels.length){let sum=0,count=0;for(const ch of channels)for(const x of ch){count++;sum+=x*x;this.peak=Math.max(this.peak,Math.abs(x));if(x!==0)this.nonzero++;}this.samples+=count;let rms=Math.sqrt(sum/Math.max(1,count));this.maxRms=Math.max(this.maxRms,rms);if(rms>=.005)this.activeSamples+=channels[0].length;this.tick+=channels[0].length;if(this.tick>=sampleRate/2){this.tick=0;this.port.postMessage({samples:this.samples,nonzero:this.nonzero,peak:this.peak,maxRms:this.maxRms,rms,activeSeconds:this.activeSamples/sampleRate,rate:sampleRate,channels:channels.length});}}return true;}
}
registerProcessor('meter',Meter);
