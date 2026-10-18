import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/fft.dart';
import '../dsp/pcm.dart';
import '../onnx.dart';

class ClapFeatures {
  ClapFeatures(this.features, this.frames, this.bins, this.isLonger, this.resampledLength);

  /// Row-major [frames, bins] log-mel (dB).
  final Float32List features;
  final int frames;
  final int bins;
  final bool isLonger;
  final int resampledLength;
}

/// Port of kiarina's `ClapOnnxAudioEmbeddingProvider` with its NumPy log-mel
/// front end ("clap-log-mel-numpy", pre=logmel-v1). Defaults are the
/// laion/clap-htsat-unfused preprocessor_config.json values with kiarina's
/// padding/truncation overrides.
class ClapSoundEmbedder {
  ClapSoundEmbedder(
    this.model, {
    this.sampleRate = 48000,
    this.featureSize = 64,
    this.fftWindowSize = 1024,
    this.hopLength = 480,
    this.frequencyMin = 50,
    this.frequencyMax = 14000,
    this.maxSamples = 480000,
    this.padding = 'repeatpad',
    this.truncation = 'center',
  })  : _fft = Fft(fftWindowSize),
        _melFilters = _melFilterBank(fftWindowSize ~/ 2 + 1, featureSize, frequencyMin, frequencyMax, sampleRate),
        _window = _hann(fftWindowSize);

  final OnnxModel model;
  final int sampleRate;
  final int featureSize;
  final int fftWindowSize;
  final int hopLength;
  final double frequencyMin;
  final double frequencyMax;
  final int maxSamples;
  final String padding;
  final String truncation;

  final Fft _fft;

  /// Row-major [bins, mels] float32 (as in Python).
  final Float32List _melFilters;
  final Float64List _window;

  Future<Float32List> embed(Float32List samples, int sourceRate) async {
    final f = extractFeatures(samples, sourceRate);
    final names = model.inputNames.toSet();
    final inputName = ['audio', 'input_features', 'input', 'waveform', 'x']
        .firstWhere(names.contains, orElse: () => model.inputNames.first);
    final inputs = <String, Tensor>{
      inputName: Tensor.float32(f.features, [1, 1, f.frames, f.bins]),
    };
    if (names.contains('is_longer')) {
      inputs['is_longer'] = Tensor.boolean([f.isLonger], const [1, 1]);
    }
    final outputs = await model.run(inputs);
    return l2Normalize(Float32List.fromList(outputs[model.outputNames.first]!.float32));
  }

  ClapFeatures extractFeatures(Float32List samples, int sourceRate) {
    samples = resampleLinear(samples, sourceRate, sampleRate);
    final resampledLength = samples.length;
    final (fitted, longer) = _fitWaveform(samples);
    final mel = _logMel(fitted);
    final expectedFrames = maxSamples ~/ hopLength + 1;
    final frames = mel.length ~/ featureSize;
    final out = Float32List(expectedFrames * featureSize);
    out.setRange(0, math.min(frames, expectedFrames) * featureSize, mel);
    return ClapFeatures(out, expectedFrames, featureSize, longer, resampledLength);
  }

  (Float32List, bool) _fitWaveform(Float32List samples) {
    if (samples.isEmpty) return (Float32List(maxSamples), false);
    if (samples.length > maxSamples) {
      final start = truncation == 'center' ? (samples.length - maxSamples) ~/ 2 : 0;
      return (Float32List.fromList(samples.sublist(start, start + maxSamples)), true);
    }
    if (samples.length == maxSamples) return (samples, false);
    final out = Float32List(maxSamples);
    var source = samples;
    if (padding == 'repeat' || padding == 'repeatpad') {
      final repeatCount = maxSamples ~/ samples.length;
      final repeats = padding == 'repeatpad' ? repeatCount : repeatCount + 1;
      source = Float32List(samples.length * repeats);
      for (var r = 0; r < repeats; r++) {
        source.setRange(r * samples.length, (r + 1) * samples.length, samples);
      }
    }
    final n = math.min(source.length, maxSamples);
    out.setRange(0, n, source);
    return (out, false);
  }

  Float32List _logMel(Float32List samples) {
    final n = fftWindowSize;
    final pad = n ~/ 2;
    final padded = Float64List(samples.length + 2 * pad);
    for (var i = 0; i < samples.length; i++) {
      padded[pad + i] = samples[i];
    }
    if (samples.length > 1) {
      // numpy "reflect" (edge sample not repeated).
      for (var i = 0; i < pad; i++) {
        padded[pad - 1 - i] = samples[_reflect(i + 1, samples.length)];
        padded[pad + samples.length + i] = samples[_reflect(samples.length - 2 - i, samples.length)];
      }
    }
    final numFrames = 1 + (padded.length - n) ~/ hopLength;
    final bins = n ~/ 2 + 1;
    final frame = Float64List(n);
    final re = Float64List(n), im = Float64List(n), power = Float64List(bins);
    final out = Float32List(numFrames * featureSize);
    for (var t = 0; t < numFrames; t++) {
      final offset = t * hopLength;
      for (var i = 0; i < n; i++) {
        // frames (float32) * window (float32) in numpy stays float32.
        frame[i] = _f32(padded[offset + i] * _window[i]);
      }
      _fft.powerSpectrum(frame, re, im, power);
      for (var m = 0; m < featureSize; m++) {
        var sum = 0.0;
        for (var k = 0; k < bins; k++) {
          sum += power[k] * _melFilters[k * featureSize + m];
        }
        // Python rounds the mel power to float32 before log10.
        out[t * featureSize + m] = 10.0 * math.log(_f32(math.max(sum, 1e-10))) / math.ln10;
      }
    }
    return out;
  }

  static int _reflect(int i, int length) {
    final period = 2 * (length - 1);
    var j = i % period;
    if (j < 0) j += period;
    return j < length ? j : period - j;
  }

  static final _scratch = Float32List(1);

  static double _f32(double x) {
    _scratch[0] = x;
    return _scratch[0];
  }

  static Float64List _hann(int n) {
    // np.hanning(n + 1)[:-1] as float32.
    final w = Float64List(n);
    for (var i = 0; i < n; i++) {
      w[i] = _f32(0.5 - 0.5 * math.cos(2 * math.pi * i / n));
    }
    return w;
  }

  static Float32List _melFilterBank(int bins, int mels, double fMin, double fMax, int sr) {
    double hzToMel(double f) => 2595.0 * math.log(1.0 + f / 700.0) / math.ln10;
    final minMel = hzToMel(fMin), maxMel = hzToMel(fMax);
    final hz = Float32List(mels + 2);
    for (var i = 0; i < mels + 2; i++) {
      final mel = minMel + (maxMel - minMel) * i / (mels + 1);
      hz[i] = 700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);
    }
    final filters = Float32List(bins * mels);
    for (var m = 0; m < mels; m++) {
      final lower = hz[m], center = hz[m + 1], upper = hz[m + 2];
      for (var k = 0; k < bins; k++) {
        final f = (sr / 2) * k / (bins - 1);
        final up = (f - lower) / math.max(center - lower, 1e-12);
        final down = (upper - f) / math.max(upper - center, 1e-12);
        filters[k * mels + m] = math.max(0.0, math.min(up, down));
      }
    }
    return filters;
  }
}
