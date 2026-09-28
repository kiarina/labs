// Caps every embedded image in a GLB/VRM at a maximum edge length and writes
// a new GLB. Everything else (JSON, accessors, VRM extensions) is kept; only
// the binary chunk is repacked because the image buffer views change size.
//
//   dart run tool/shrink_vrm.dart <in.vrm> <out.vrm> [maxEdge=1024]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: shrink_vrm.dart <in> <out> [maxEdge]');
    exit(64);
  }
  final maxEdge = args.length > 2 ? int.parse(args[2]) : 1024;
  final bytes = File(args[0]).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  final jsonLen = bd.getUint32(12, Endian.little);
  final json =
      jsonDecode(utf8.decode(bytes.sublist(20, 20 + jsonLen)))
          as Map<String, dynamic>;
  final binStart = 20 + jsonLen + 8;
  final binLen = bd.getUint32(20 + jsonLen, Endian.little);
  final bin = bytes.sublist(binStart, binStart + binLen);

  final views = (json['bufferViews'] as List).cast<Map<String, dynamic>>();
  final viewBytes = [
    for (final v in views)
      Uint8List.sublistView(
        bin,
        v['byteOffset'] as int? ?? 0,
        (v['byteOffset'] as int? ?? 0) + (v['byteLength'] as int),
      ),
  ];

  var shrunk = 0;
  for (final image in (json['images'] as List? ?? const [])
      .cast<Map<String, dynamic>>()) {
    final viewIndex = image['bufferView'] as int?;
    if (viewIndex == null) continue;
    final decoded = img.decodeImage(viewBytes[viewIndex]);
    if (decoded == null) continue;
    final edge =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    if (edge <= maxEdge) continue;
    final scale = maxEdge / edge;
    final resized = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
    viewBytes[viewIndex] = img.encodePng(resized);
    image['mimeType'] = 'image/png';
    shrunk++;
  }

  // Repack the binary chunk with 4-byte alignment.
  final out = BytesBuilder();
  for (var i = 0; i < views.length; i++) {
    while (out.length % 4 != 0) {
      out.addByte(0);
    }
    views[i]['byteOffset'] = out.length;
    views[i]['byteLength'] = viewBytes[i].length;
    out.add(viewBytes[i]);
  }
  while (out.length % 4 != 0) {
    out.addByte(0);
  }
  final newBin = out.toBytes();
  (json['buffers'] as List)[0]['byteLength'] = newBin.length;

  var jsonBytes = utf8.encode(jsonEncode(json));
  final pad = (4 - jsonBytes.length % 4) % 4;
  jsonBytes = Uint8List.fromList([...jsonBytes, ...List.filled(pad, 0x20)]);

  final total = 12 + 8 + jsonBytes.length + 8 + newBin.length;
  final header = ByteData(12)
    ..setUint32(0, 0x46546C67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, total, Endian.little);
  final result = BytesBuilder()
    ..add(header.buffer.asUint8List())
    ..add((ByteData(8)
          ..setUint32(0, jsonBytes.length, Endian.little)
          ..setUint32(4, 0x4E4F534A, Endian.little))
        .buffer
        .asUint8List())
    ..add(jsonBytes)
    ..add((ByteData(8)
          ..setUint32(0, newBin.length, Endian.little)
          ..setUint32(4, 0x004E4942, Endian.little))
        .buffer
        .asUint8List())
    ..add(newBin);
  File(args[1]).writeAsBytesSync(result.toBytes());
  stdout.writeln('${args[0]} -> ${args[1]}: $shrunk images capped at '
      '$maxEdge, ${bytes.length ~/ 1024} KB -> ${total ~/ 1024} KB');
}
