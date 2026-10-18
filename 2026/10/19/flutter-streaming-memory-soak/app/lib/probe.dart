import 'dart:io';

import 'package:flutter/services.dart';
// Deliberately coupled to the pinned 3.6.7 internals for an A/B workaround.
// ignore: implementation_imports
import 'package:ffmpeg_kit_flutter_new_min/src/ffmpeg_kit_factory.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';

bool get cleanCallbacks => Platform.environment['CLEAN_CALLBACKS'] != '0';
Map<String, int> callbackCounts() => {
  'ffmpeg_complete': ffmpegSessionCompleteCallbackMap.length,
  'ffprobe_complete': ffprobeSessionCompleteCallbackMap.length,
  'media_complete': mediaInformationSessionCompleteCallbackMap.length,
  'log': logCallbackMap.length,
  'statistics': statisticsCallbackMap.length,
  'redirection': logRedirectionStrategyMap.length,
};
void releaseCallbacks(int id) {
  ffmpegSessionCompleteCallbackMap.remove(id);
  ffprobeSessionCompleteCallbackMap.remove(id);
  mediaInformationSessionCompleteCallbackMap.remove(id);
  logCallbackMap.remove(id);
  statisticsCallbackMap.remove(id);
  logRedirectionStrategyMap.remove(id);
}

Future<Map<String, Object?>> snapshot() async {
  final native = await const MethodChannel('memory_soak/probe')
      .invokeMapMethod<String, Object?>('snapshot');
  final ort = await const MethodChannel('flutter_onnxruntime')
      .invokeMapMethod<String, Object?>('memoryProbe');
  final history = await FFmpegKitConfig.getSessions();
  return {
    'rss': ProcessInfo.currentRss,
    'max_rss': ProcessInfo.maxRss,
    ...?native,
    'ort': ort,
    'callbacks': callbackCounts(),
    'ffmpeg_history': history.length,
  };
}

Future<int?> relieve() =>
    const MethodChannel('memory_soak/probe').invokeMethod<int>('relieve');

Future<void> beginWork() =>
    const MethodChannel('memory_soak/probe').invokeMethod<void>('beginWork');
Future<void> endWork() =>
    const MethodChannel('memory_soak/probe').invokeMethod<void>('endWork');
