/* 16 kHz mono signed little-endian PCM, ~100 ms frames. No audio leaves here. */
class SeraPcmProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / 16000;
    this.weight = 0;
    this.sum = 0;
    this.frame = new Int16Array(1600);
    this.used = 0;
    this.stopped = false;
    this.port.onmessage = ({data}) => {
      if (data?.type === 'stop') {
        if (!data.cancel && this.used) this.send(this.frame.slice(0, this.used));
        this.used = 0;
        this.stopped = true;
        this.port.postMessage({type: 'stopped'});
      }
    };
  }
  send(samples) {
    const bytes = new ArrayBuffer(samples.length * 2);
    const view = new DataView(bytes);
    for (let i = 0; i < samples.length; i++) view.setInt16(i * 2, samples[i], true);
    this.port.postMessage({type: 'pcm', bytes}, [bytes]);
  }
  process(inputs, outputs) {
    for (const output of outputs) for (const channel of output) channel.fill(0);
    if (this.stopped) return false;
    const channels = inputs[0];
    if (!channels?.length) return true;
    for (let i = 0; i < channels[0].length; i++) {
      let sample = 0;
      for (const channel of channels) sample += channel[i] || 0;
      sample /= channels.length;
      let remainder = 1;
      while (remainder > 1e-9) {
        const take = Math.min(remainder, this.ratio - this.weight);
        this.sum += sample * take;
        this.weight += take;
        remainder -= take;
        if (this.weight >= this.ratio - 1e-9) {
          const value = Math.max(-1, Math.min(1, this.sum / this.ratio));
          this.frame[this.used++] = Math.round(value * (value < 0 ? 32768 : 32767));
          this.weight = 0;
          this.sum = 0;
          if (this.used === this.frame.length) {
            this.send(this.frame);
            this.frame = new Int16Array(1600);
            this.used = 0;
          }
        }
      }
    }
    return true;
  }
}
registerProcessor('sera-pcm', SeraPcmProcessor);
