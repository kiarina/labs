import 'dart:io';
import 'dart:typed_data';

import 'package:pcm_asr/pcm_asr_windows.dart';

String platformName() => Platform.operatingSystem;

/// Windows: `TTS_ASR_MODEL_DIR` points pcm_asr at an existing whisper model
/// folder so the lab does not download 574 MB again.
void configurePlatform() {
  final dir = Platform.environment['TTS_ASR_MODEL_DIR'];
  if (Platform.isWindows && dir != null && dir.isNotEmpty) {
    PcmAsrWindows.modelDirectory = () async => Directory(dir);
  }
}

/// Desktop: `TTS_CONFIG`. Android: the `config` intent extra exported to
/// `TTS_CONFIG` by MainActivity. iOS: `<tmp>/tts_config.json` pushed with
/// devicectl.
String? configJson() {
  final env = Platform.environment['TTS_CONFIG'];
  if (env != null && env.isNotEmpty) return env;
  final file = File('${Directory.systemTemp.path}/tts_config.json');
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// Written to the temp dir and printed in numbered chunks (Android's log cuts
/// lines at ~1 KB; iOS release builds do not forward print).
void writeResult(String json) {
  try {
    File('${Directory.systemTemp.path}/tts_result.json').writeAsStringSync(json);
  } catch (_) {}
  const size = 800;
  final count = (json.length / size).ceil();
  for (var i = 0; i < count; i++) {
    final end = (i + 1) * size < json.length ? (i + 1) * size : json.length;
    // ignore: avoid_print
    print('TTS_PART ${i + 1}/$count ${json.substring(i * size, end)}');
  }
}

void exitApp() => exit(0);

/// Synthesized audio kept on the device for listening (not committed).
Future<void> saveWav(String name, Int16List pcm, int rate) async {
  final dir = Directory('${Directory.systemTemp.path}/tts_wavs');
  await dir.create(recursive: true);
  final data = ByteData(44 + pcm.length * 2);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, pcm.length * 2, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    data.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  await File('${dir.path}/$name').writeAsBytes(data.buffer.asUint8List());
}
