import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'onnx.dart';

/// onnxruntime-web called directly (the page loads `ort.min.js`).
///
/// flutter_onnxruntime's web side builds int64 tensors from Dart's
/// Int64List, which dart2js does not have, so Silero VAD's `sr` input
/// cannot be passed through it. Here int64 tensors are BigInt64Arrays made
/// in JS.
class WebOnnxBackend implements OnnxBackend {
  WebOnnxBackend({this.threads});

  final int? threads;

  JSObject get _ort => globalContext['ort'] as JSObject;

  @override
  Future<OnnxModel> load(String location) async {
    if (threads != null) {
      ((_ort['env'] as JSObject)['wasm'] as JSObject)['numThreads'] = threads!.toJS;
    }
    final cls = _ort['InferenceSession'] as JSObject;
    final options = JSObject()..['executionProviders'] = ['wasm'.toJS].toJS;
    final session =
        await (cls.callMethodVarArgs<JSPromise<JSObject>>('create'.toJS, [location.toJS, options])).toDart;
    return _WebOnnxModel(_ort, session);
  }
}

class _WebOnnxModel implements OnnxModel {
  _WebOnnxModel(this._ort, this._session)
      : inputNames = _names(_session['inputNames']),
        outputNames = _names(_session['outputNames']);

  final JSObject _ort;
  final JSObject _session;

  @override
  final List<String> inputNames;

  @override
  final List<String> outputNames;

  static List<String> _names(JSAny? a) => [for (final n in (a as JSArray<JSString>).toDart) n.toDart];

  JSObject _tensor(Tensor t) {
    final ctor = _ort['Tensor'] as JSFunction;
    final dims = [for (final d in t.shape) d.toJS].toJS;
    final data = t.data;
    if (data is Float32List) {
      return ctor.callAsConstructorVarArgs<JSObject>(['float32'.toJS, data.toJS, dims]);
    }
    if (data is List<bool>) {
      final u8 = Uint8List.fromList([for (final b in data) b ? 1 : 0]);
      return ctor.callAsConstructorVarArgs<JSObject>(['bool'.toJS, u8.toJS, dims]);
    }
    if (data is List<int>) {
      final bigInt = globalContext['BigInt'] as JSFunction;
      final arr = (globalContext['BigInt64Array'] as JSFunction).callAsConstructorVarArgs<JSObject>([data.length.toJS]);
      for (var i = 0; i < data.length; i++) {
        arr[i.toString()] = bigInt.callAsFunction(null, data[i].toJS);
      }
      return ctor.callAsConstructorVarArgs<JSObject>(['int64'.toJS, arr, dims]);
    }
    throw ArgumentError('unsupported tensor data ${data.runtimeType}');
  }

  @override
  Future<Map<String, Tensor>> run(Map<String, Tensor> inputs) async {
    final feeds = JSObject();
    for (final e in inputs.entries) {
      feeds[e.key] = _tensor(e.value);
    }
    final out = await _session.callMethod<JSPromise<JSObject>>('run'.toJS, feeds).toDart;
    final result = <String, Tensor>{};
    for (final name in outputNames) {
      final t = out[name] as JSObject?;
      if (t == null) continue;
      final dims = [for (final d in (t['dims'] as JSArray<JSNumber>).toDart) d.toDartInt];
      final type = (t['type'] as JSString).toDart;
      final data = t['data'] as JSObject;
      if (type == 'float32') {
        result[name] = Tensor(Float32List.fromList((data as JSFloat32Array).toDart), dims);
      } else {
        final n = (data['length'] as JSNumber).toDartInt;
        final number = globalContext['Number'] as JSFunction;
        result[name] = Tensor(
          Float32List.fromList([
            for (var i = 0; i < n; i++) (number.callAsFunction(null, data[i.toString()]) as JSNumber).toDartDouble,
          ]),
          dims,
        );
      }
    }
    return result;
  }

  @override
  Future<void> close() async {
    await _session.callMethod<JSPromise<JSAny?>>('release'.toJS).toDart;
  }
}
