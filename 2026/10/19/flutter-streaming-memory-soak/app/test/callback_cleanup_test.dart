import 'package:flutter_test/flutter_test.dart';
// Pinned dependency internals are the subject of this regression test.
// ignore: implementation_imports
import 'package:ffmpeg_kit_flutter_new_min/src/ffmpeg_kit_factory.dart';
import 'package:memory_soak_lab/probe.dart';

void main() {
  tearDown(() {
    for (final id in [900001, 900002]) {
      releaseCallbacks(id);
    }
  });
  test('releasing a completed session preserves another active session', () {
    ffmpegSessionCompleteCallbackMap[900001] = (_) {};
    ffmpegSessionCompleteCallbackMap[900002] = (_) {};
    logCallbackMap[900001] = (_) {};
    logCallbackMap[900002] = (_) {};
    statisticsCallbackMap[900001] = (_) {};
    statisticsCallbackMap[900002] = (_) {};
    releaseCallbacks(900001);
    expect(ffmpegSessionCompleteCallbackMap.containsKey(900001), false);
    expect(logCallbackMap.containsKey(900001), false);
    expect(statisticsCallbackMap.containsKey(900001), false);
    expect(ffmpegSessionCompleteCallbackMap.containsKey(900002), true);
    expect(logCallbackMap.containsKey(900002), true);
    expect(statisticsCallbackMap.containsKey(900002), true);
  });
  test('cleanup is idempotent', () {
    ffmpegSessionCompleteCallbackMap[900001] = (_) {};
    releaseCallbacks(900001);
    releaseCallbacks(900001);
    expect(ffmpegSessionCompleteCallbackMap.containsKey(900001), false);
  });
}
