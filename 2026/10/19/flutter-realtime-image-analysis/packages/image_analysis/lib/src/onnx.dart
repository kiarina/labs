import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// A tensor passed to or returned from a model. [data] is a Float32List,
/// a List<int> (int64; dart2js has no Int64List) or a List<bool>.
class Tensor {
  Tensor(this.data, this.shape);

  Tensor.float32(Float32List data, this.shape) : data = data;
  Tensor.int64(List<int> data, this.shape) : data = data;
  Tensor.boolean(List<bool> data, this.shape) : data = data;

  final Object data;
  final List<int> shape;

  Float32List get float32 => data as Float32List;
}

/// What the analysis code needs from an ONNX runtime. Kept small so the
/// pipeline can run against a fake in unit tests and against
/// flutter_onnxruntime in the app.
abstract class OnnxModel {
  List<String> get inputNames;
  List<String> get outputNames;
  /// Runs the model. With [outputs], only those outputs are copied back to
  /// Dart (the others are released in the runtime).
  Future<Map<String, Tensor>> run(Map<String, Tensor> inputs, {Set<String>? outputs});
  Future<void> close();
}

abstract class OnnxBackend {
  /// [location] is a file path (native) or URL (web).
  Future<OnnxModel> load(String location);
}

class FlutterOnnxBackend implements OnnxBackend {
  FlutterOnnxBackend({this.threads});

  final int? threads;
  final _runtime = OnnxRuntime();

  @override
  Future<OnnxModel> load(String location) async {
    final session = await _runtime.createSession(
      location,
      options: OrtSessionOptions(
        intraOpNumThreads: threads,
        providers: const [OrtProvider.CPU],
      ),
    );
    return _FlutterOnnxModel(session);
  }
}

class _FlutterOnnxModel implements OnnxModel {
  _FlutterOnnxModel(this._session);

  final OrtSession _session;

  @override
  List<String> get inputNames => _session.inputNames;

  @override
  List<String> get outputNames => _session.outputNames;

  @override
  Future<Map<String, Tensor>> run(Map<String, Tensor> inputs, {Set<String>? outputs}) async {
    final values = <String, OrtValue>{};
    try {
      for (final e in inputs.entries) {
        var data = e.value.data;
        if (data is List<int> && data is! Int64List) data = Int64List.fromList(data);
        values[e.key] = await OrtValue.fromList(data, e.value.shape);
      }
      final produced = await _session.run(values);
      final result = <String, Tensor>{};
      for (final e in produced.entries) {
        final v = e.value;
        try {
          if (outputs != null && !outputs.contains(e.key)) continue;
          final flat = await v.asFlattenedList();
          result[e.key] = Tensor(_toTyped(flat, v.dataType), v.shape);
        } finally {
          await v.dispose();
        }
      }
      return result;
    } finally {
      for (final v in values.values) {
        await v.dispose();
      }
    }
  }

  Object _toTyped(List<dynamic> flat, OrtDataType type) {
    switch (type) {
      case OrtDataType.float32:
        if (flat is Float32List) return flat;
        return Float32List.fromList([for (final x in flat) (x as num).toDouble()]);
      case OrtDataType.int64:
        if (flat is Int64List) return flat;
        return Int64List.fromList([for (final x in flat) (x as num).toInt()]);
      case OrtDataType.bool:
        return [for (final x in flat) x == true || x == 1];
      default:
        return Float32List.fromList([for (final x in flat) (x as num).toDouble()]);
    }
  }

  @override
  Future<void> close() => _session.close();
}
