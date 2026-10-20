// Streaming MeanVC2 (120ms model) on flutter_onnxruntime.
//
// A port of py/onnx_stream.py, which itself is upstream runtime/run_rt.py
// `VCRunner.process_chunk` with the model calls replaced by the exported
// graphs. The ASR and DiT caches stay native (OrtValue handles fed back into
// the next run) so that only the per-chunk inputs and the outputs that the
// host code needs cross the platform channel.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

const int kChunk = 2560; // 160 ms at 16 kHz
const int _bnWindow = 19;
const int _bnStride = 16;
const int _requiredCache = 8;
const int _asrOffsetInit = 8;
const int _asrOffsetStep = 4;
const int _chunkSize = 12;
const int _blockSize = 4;
const int _vocoderOverlap = 2;
const int _wavOverlap = 160;
const int _wavPad = (_vocoderOverlap - 1) * 160 - _wavOverlap; // 0
const int _layers = 4;

typedef NoiseFn = Float32List Function(int n);

class MeanVc2Stream {
  MeanVc2Stream._(this._s, this.steps, this.loadMs);

  final Map<String, OrtSession> _s;
  int steps;
  final double loadMs;
  NoiseFn? noiseFn;
  final _rng = math.Random(0);

  /// Wall time spent in each graph (including the channel round trips).
  final Map<String, double> timing = {'fbank': 0, 'asr': 0, 'dit': 0, 'vocos': 0, 'host': 0};

  static Future<MeanVc2Stream> load(String dir, {Map<String, String> suffix = const {}, int? threads, int steps = 3}) async {
    final rt = OnnxRuntime();
    final sw = Stopwatch()..start();
    final sessions = <String, OrtSession>{};
    for (final n in ['fbank', 'asr', 'gtm', 'dit', 'vocos']) {
      sessions[n] = await rt.createSession('$dir/$n${suffix[n] ?? ''}.onnx',
          options: OrtSessionOptions(intraOpNumThreads: threads, interOpNumThreads: 1, providers: const [OrtProvider.CPU]));
    }
    return MeanVc2Stream._(sessions, steps, sw.elapsedMicroseconds / 1000);
  }

  // speaker
  OrtValue? _spk, _kMem, _vMem;

  Future<void> setTarget(Float32List spk) async {
    await _disposeTarget();
    _spk = await OrtValue.fromList(spk, [1, 256]);
    final out = await _s['gtm']!.run({'spks': _spk!});
    _kMem = out['k_mem'];
    _vMem = out['v_mem'];
    await reset();
  }

  Future<void> _disposeTarget() async {
    for (final v in [_spk, _kMem, _vMem]) {
      await v?.dispose();
    }
  }

  // streaming state
  Float32List _samplesCache = Float32List(0);
  Float32List? _frameCache; // rows of 80
  Float32List? _encoderOutputCache; // one row of 256
  int _asrOffset = _asrOffsetInit;
  OrtValue? _att, _cnn;
  List<OrtValue> _kv = [];
  int _vcOffset = 0;
  Float32List? _noiseCache; // 4 x 80
  Float32List? _vocoderCache; // 80 x 2 (row-major [c][t])
  Float32List? _lastWav;
  Float32List? _bnBuffer; // rows of 256

  Future<void> reset() async {
    _samplesCache = Float32List(0);
    _frameCache = null;
    _encoderOutputCache = null;
    _asrOffset = _asrOffsetInit;
    await _att?.dispose();
    await _cnn?.dispose();
    _att = await OrtValue.fromList(Float32List(6 * 4 * _requiredCache * 128), [6, 4, _requiredCache, 128]);
    _cnn = await OrtValue.fromList(Float32List(6 * 1 * 256 * 8), [6, 1, 256, 8]);
    await _resetKv();
    _vcOffset = 0;
    _noiseCache = null;
    _vocoderCache = null;
    _lastWav = null;
    _bnBuffer = null;
    timing.updateAll((k, v) => 0);
  }

  Future<void> _resetKv() async {
    for (final v in _kv) {
      await v.dispose();
    }
    _kv = [for (var i = 0; i < 2 * _layers; i++) await OrtValue.fromList(Float32List(0), [1, 2, 0, 64])];
  }

  static Float32List _cat(Float32List? a, Float32List b) {
    if (a == null || a.isEmpty) return b;
    final out = Float32List(a.length + b.length);
    out.setAll(0, a);
    out.setAll(a.length, b);
    return out;
  }

  Future<Float32List> _read(OrtValue v) async {
    final flat = await v.asFlattenedList();
    if (flat is Float32List) return flat;
    return Float32List.fromList([for (final x in flat) (x as num).toDouble()]);
  }

  // ---------------------------------------------------------------- ASR
  Future<Float32List?> _encodeChunk(Float32List samples) async {
    final padded = _cat(_samplesCache, samples);
    if (padded.length < 400) {
      _samplesCache = padded;
      return null;
    }
    final n = 1 + (padded.length - 400) ~/ 160;
    final frames = Float32List(n * 400);
    for (var f = 0; f < n; f++) {
      for (var i = 0; i < 400; i++) {
        frames[f * 400 + i] = padded[f * 160 + i] * 32768.0;
      }
    }
    final sw = Stopwatch()..start();
    final fIn = await OrtValue.fromList(frames, [n, 400]);
    final fOut = await _s['fbank']!.run({'frames': fIn});
    var fb = await _read(fOut['fbank']!);
    await fIn.dispose();
    await fOut['fbank']!.dispose();
    timing['fbank'] = timing['fbank']! + sw.elapsedMicroseconds / 1000;
    _samplesCache = Float32List.fromList(padded.sublist(160 * n));
    fb = _cat(_frameCache, fb);
    final rows = fb.length ~/ 80;
    if (_asrOffset >= 4000) _asrOffset = math.max(_requiredCache, _asrOffset - 4000);
    final bns = <Float32List>[];
    var i = 0;
    final asw = Stopwatch()..start();
    final rcs = await OrtValue.fromList(Int64List.fromList([_requiredCache]), []);
    while (i + _bnWindow <= rows) {
      final xs = await OrtValue.fromList(Float32List.sublistView(fb, i * 80, (i + _bnWindow) * 80), [1, _bnWindow, 80]);
      final off = await OrtValue.fromList(Int64List.fromList([_asrOffset]), []);
      final out = await _s['asr']!.run({'xs': xs, 'offset': off, 'required_cache_size': rcs, 'att_cache': _att!, 'cnn_cache': _cnn!});
      await xs.dispose();
      await off.dispose();
      await _att!.dispose();
      await _cnn!.dispose();
      _att = out['new_att_cache'];
      _cnn = out['new_cnn_cache'];
      bns.add(await _read(out['bn']!));
      await out['bn']!.dispose();
      _asrOffset += _asrOffsetStep;
      i += _bnStride;
    }
    await rcs.dispose();
    timing['asr'] = timing['asr']! + asw.elapsedMicroseconds / 1000;
    _frameCache = Float32List.fromList(fb.sublist(i * 80));
    if (bns.isEmpty) return null;
    var bn = bns.length == 1 ? bns.first : bns.reduce(_cat);
    bn = _cat(_encoderOutputCache, bn);
    final nb = bn.length ~/ 256;
    _encoderOutputCache = Float32List.fromList(bn.sublist((nb - 1) * 256));
    if (nb < 2) return null;
    return _interp(bn, nb, 17, 256, dropFirst: true);
  }

  /// F.interpolate(mode='linear', align_corners=True) along the rows.
  static Float32List _interp(Float32List x, int n, int size, int c, {bool dropFirst = false}) {
    final start = dropFirst ? 1 : 0;
    final out = Float32List((size - start) * c);
    final scale = (n - 1) / (size - 1);
    for (var j = start; j < size; j++) {
      final pos = j * scale;
      final lo = math.min(pos.floor(), n - 2);
      final w = pos - lo;
      final o = (j - start) * c;
      for (var k = 0; k < c; k++) {
        out[o + k] = x[lo * c + k] * (1 - w) + x[(lo + 1) * c + k] * w;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- DiT
  Float32List _noise(int n) {
    final f = noiseFn;
    if (f != null) return f(n);
    final out = Float32List(n * 80);
    for (var i = 0; i < out.length; i += 2) {
      // Box-Muller
      final u1 = 1.0 - _rng.nextDouble();
      final u2 = _rng.nextDouble();
      final r = math.sqrt(-2 * math.log(u1));
      out[i] = r * math.cos(2 * math.pi * u2);
      if (i + 1 < out.length) out[i + 1] = r * math.sin(2 * math.pi * u2);
    }
    return out;
  }

  Future<Float32List> _vcStep(Float32List cond, int frames) async {
    final n = steps;
    final dt = 1.0 / n;
    var x = Float32List.fromList(_noise(frames));
    if (_noiseCache != null) x.setAll(0, _noiseCache!);
    _noiseCache = Float32List.fromList(x.sublist((frames - _blockSize) * 80));
    if (_vcOffset >= 4000) {
      _vcOffset = 0;
      await _resetKv();
    }
    final sw = Stopwatch()..start();
    final condV = await OrtValue.fromList(cond, [1, frames, 256]);
    final offV = await OrtValue.fromList(Int64List.fromList([_vcOffset]), []);
    final feed = <String, OrtValue>{'cond': condV, 'spks': _spk!, 'k_mem': _kMem!, 'v_mem': _vMem!, 'offset': offV};
    for (var j = 0; j < _layers; j++) {
      feed['k_cache$j'] = _kv[2 * j];
      feed['v_cache$j'] = _kv[2 * j + 1];
    }
    List<OrtValue>? newKv;
    for (var i = 0; i < n; i++) {
      final tVal = 1.0 - i * dt;
      final rVal = math.max(0.0, tVal - dt);
      final xV = await OrtValue.fromList(x, [1, frames, 80]);
      final tV = await OrtValue.fromList(Float32List.fromList([tVal]), [1]);
      final rV = await OrtValue.fromList(Float32List.fromList([rVal]), [1]);
      feed['x'] = xV;
      feed['t'] = tV;
      feed['r'] = rV;
      final out = await _s['dit']!.run(feed);
      final u = await _read(out['u']!);
      await out['u']!.dispose();
      final kv = [for (var j = 0; j < _layers; j++) ...[out['new_k_cache$j']!, out['new_v_cache$j']!]];
      if (i == n - 1) {
        newKv = kv;
      } else {
        for (final v in kv) {
          await v.dispose();
        }
      }
      for (final v in [xV, tV, rV]) {
        await v.dispose();
      }
      final nx = Float32List(x.length);
      for (var k = 0; k < x.length; k++) {
        nx[k] = x[k] - dt * u[k];
      }
      x = nx;
    }
    await condV.dispose();
    await offV.dispose();
    for (final v in _kv) {
      await v.dispose();
    }
    _kv = newKv!;
    timing['dit'] = timing['dit']! + sw.elapsedMicroseconds / 1000;
    _vcOffset += _chunkSize;
    // mel [1, 80, 12]: mel[c][t] = x[t][c]
    final mel = Float32List(80 * _chunkSize);
    for (var t = 0; t < _chunkSize; t++) {
      for (var c = 0; c < 80; c++) {
        mel[c * _chunkSize + t] = x[t * 80 + c];
      }
    }
    return mel;
  }

  // ---------------------------------------------------------------- vocoder
  Future<Float32List> _decodeMel(Float32List mel, int frames) async {
    var t = frames;
    var m = mel;
    if (_vocoderCache != null) {
      final ct = _vocoderOverlap;
      final joined = Float32List(80 * (ct + t));
      for (var c = 0; c < 80; c++) {
        for (var k = 0; k < ct; k++) {
          joined[c * (ct + t) + k] = _vocoderCache![c * ct + k];
        }
        for (var k = 0; k < t; k++) {
          joined[c * (ct + t) + ct + k] = m[c * t + k];
        }
      }
      m = joined;
      t += ct;
    }
    final cache = Float32List(80 * _vocoderOverlap);
    for (var c = 0; c < 80; c++) {
      for (var k = 0; k < _vocoderOverlap; k++) {
        cache[c * _vocoderOverlap + k] = m[c * t + t - _vocoderOverlap + k];
      }
    }
    _vocoderCache = cache;
    final scaled = Float32List(m.length);
    for (var k = 0; k < m.length; k++) {
      scaled[k] = (m[k] + 1) / 2;
    }
    final sw = Stopwatch()..start();
    final melV = await OrtValue.fromList(scaled, [1, 80, t]);
    final out = await _s['vocos']!.run({'mel': melV});
    var wav = await _read(out['wav']!);
    await melV.dispose();
    await out['wav']!.dispose();
    timing['vocos'] = timing['vocos']! + sw.elapsedMicroseconds / 1000;
    Float32List result;
    if (_lastWav != null) {
      wav = Float32List.sublistView(wav, _wavPad);
      result = Float32List(wav.length - _wavOverlap);
      for (var k = 0; k < _wavOverlap; k++) {
        final down = 1 - k / (_wavOverlap - 1);
        final up = k / (_wavOverlap - 1);
        result[k] = _lastWav![k] * down + wav[k] * up;
      }
      result.setAll(_wavOverlap, wav.sublist(_wavOverlap, wav.length - _wavOverlap));
    } else {
      result = Float32List.fromList(wav.sublist(0, wav.length - _wavOverlap));
    }
    _lastWav = Float32List.fromList(wav.sublist(wav.length - _wavOverlap));
    return result;
  }

  /// Feeds 160 ms (or any number) of 16 kHz samples; returns the converted
  /// samples produced so far (possibly none).
  Future<Float32List> process(Float32List samples) async {
    final total = Stopwatch()..start();
    final before = timing['fbank']! + timing['asr']! + timing['dit']! + timing['vocos']!;
    final bnNew = await _encodeChunk(samples);
    Float32List out = Float32List(0);
    if (bnNew != null) {
      _bnBuffer = _cat(_bnBuffer, bnNew);
      const need = _chunkSize + _blockSize;
      final parts = <Float32List>[];
      for (var s = 0; s < 4; s++) {
        if (_bnBuffer!.length ~/ 256 < need) break;
        final cond = Float32List.fromList(_bnBuffer!.sublist(0, need * 256));
        _bnBuffer = Float32List.fromList(_bnBuffer!.sublist(_chunkSize * 256));
        final mel = await _vcStep(cond, need);
        parts.add(await _decodeMel(mel, _chunkSize));
      }
      if (parts.isNotEmpty) out = parts.reduce(_cat);
    }
    final after = timing['fbank']! + timing['asr']! + timing['dit']! + timing['vocos']!;
    timing['host'] = timing['host']! + total.elapsedMicroseconds / 1000 - (after - before);
    return out;
  }

  Future<void> close() async {
    for (final v in [..._kv, _att, _cnn]) {
      await v?.dispose();
    }
    await _disposeTarget();
    for (final s in _s.values) {
      await s.close();
    }
  }
}
