class AecPlayback extends AudioWorkletProcessor {
  constructor() {
    super();this.queue=[];this.offset=0;this.queued=0;
    this.reference=new Int16Array(480);this.referenceCount=0;
    this.rendered=0;this.nonzero=0;this.underrun=0;this.dropped=0;
    this.port.onmessage=e=>{
      if(e.data.flush){this.queue=[];this.offset=0;this.queued=0;if(e.data.id)this.port.postMessage({flushed:e.data.id});return;}
      let pcm=e.data.pcm;
      if(pcm.length>48000){this.dropped+=pcm.length-48000;pcm=pcm.slice(pcm.length-48000);}
      // Never allow growing latency; overflow drops are counted explicitly.
      if(this.queued+pcm.length>48000){this.dropped+=this.queued;this.queue=[];this.offset=0;this.queued=0;}
      this.queue.push(pcm);this.queued+=pcm.length;
    };
  }
  process(inputs,outputs) {
    const out=outputs[0][0];
    for(let i=0;i<out.length;i++) {
      let sample=0;
      if(this.queue.length){sample=this.queue[0][this.offset++];this.queued--;
        if(this.offset===this.queue[0].length){this.queue.shift();this.offset=0;}}
      else this.underrun++;
      out[i]=sample/32768;this.reference[this.referenceCount++]=sample;this.rendered++;if(sample!==0)this.nonzero++;
      if(this.referenceCount===480){
        this.port.postMessage({reference:this.reference,frame:currentFrame+i-479,rendered:this.rendered,nonzero:this.nonzero,underrun:this.underrun,dropped:this.dropped},[this.reference.buffer]);
        this.reference=new Int16Array(480);this.referenceCount=0;
      }
    }
    return true;
  }
}
registerProcessor('aec-playback',AecPlayback);
