class PCMForwarder extends AudioWorkletProcessor {
  constructor() {
    super();
    this.tick = 0;
  }

  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    const samples = new Float32Array(channel);
    this.port.postMessage({ type: "samples", samples }, [samples.buffer]);

    if (++this.tick % 4 === 0) {
      let sum = 0;
      for (const sample of channel) sum += sample * sample;
      this.port.postMessage({ type: "level", value: Math.sqrt(sum / channel.length) });
    }
    return true;
  }
}

registerProcessor("pcm-forwarder", PCMForwarder);
