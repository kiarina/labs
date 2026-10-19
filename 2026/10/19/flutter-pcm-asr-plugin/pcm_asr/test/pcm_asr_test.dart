import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcm_asr/pcm_asr.dart';
import 'package:pcm_asr/src/method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PcmSegment', () {
    test('rejects empty and half frames', () {
      expect(() => PcmSegment(pcm16le: Uint8List(0), sampleRate: 16000), throwsArgumentError);
      expect(() => PcmSegment(pcm16le: Uint8List(3), sampleRate: 16000), throwsArgumentError);
      expect(() => PcmSegment(pcm16le: Uint8List(6), sampleRate: 16000, channels: 2), throwsArgumentError);
    });

    test('reports frames and duration', () {
      final s = PcmSegment(pcm16le: Uint8List(32000), sampleRate: 16000);
      expect(s.frameCount, 16000);
      expect(s.duration, const Duration(seconds: 1));
    });
  });

  group('MethodChannelPcmAsr', () {
    final platform = MethodChannelPcmAsr();
    final calls = <MethodCall>[];
    Object? Function(MethodCall call)? handler;

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform.methodChannel, (call) async {
        calls.add(call);
        return handler?.call(call);
      });
    });

    test('support maps every field', () async {
      handler = (_) => {
            'engine': 'apple.speech-analyzer',
            'supported': true,
            'accepts_external_pcm': true,
            'on_device': true,
            'model_state': 'installed',
            'locale': 'ja-JP',
            'sample_rates': [16000],
            'needs_network_for_model': true,
            'reason': null,
          };
      final s = await platform.support(locale: 'ja-JP');
      expect(s.supported, isTrue);
      expect(s.modelState, ModelState.installed);
      expect(s.sampleRates, [16000]);
      expect(calls.single.arguments, {'locale': 'ja-JP'});
    });

    test('transcribe passes the PCM and echoes the id', () async {
      handler = (call) => {
            'id': call.arguments['id'],
            'text': 'こんにちは',
            'engine': 'apple.speech-analyzer',
            'locale': 'ja-JP',
            'elapsed_ms': 12.5,
            'ranges': [
              {'text': 'こんにちは', 'start': 0.0, 'end': 0.8}
            ],
          };
      final pcm = Uint8List.fromList(List.filled(3200, 1));
      final r = await platform.transcribe(TranscribeRequest(
        id: 'seg-1',
        locale: 'ja-JP',
        audio: PcmSegment(pcm16le: pcm, sampleRate: 16000),
      ));
      expect(r.id, 'seg-1');
      expect(r.text, 'こんにちは');
      expect(r.elapsed, const Duration(microseconds: 12500));
      expect(r.ranges.single.end, 0.8);
      final args = calls.single.arguments as Map;
      expect(args['pcm16le'], equals(pcm));
      expect(args['sample_rate'], 16000);
      expect(args['channels'], 1);
    });

    test('platform errors become PcmAsrException with the same code', () async {
      handler = (_) => throw PlatformException(code: 'unsupportedLocale', message: 'no xx-XX');
      await expectLater(
        platform.transcribe(TranscribeRequest(
          id: 'x',
          locale: 'xx-XX',
          audio: PcmSegment(pcm16le: Uint8List(2), sampleRate: 16000),
        )),
        throwsA(isA<PcmAsrException>().having((e) => e.code, 'code', PcmAsrErrorCode.unsupportedLocale)),
      );
    });

    test('timeout cancels the request natively', () async {
      handler = (call) {
        if (call.method == 'transcribe') return Future<Object?>.delayed(const Duration(seconds: 5));
        return const <String, Object?>{};
      };
      await expectLater(
        platform.transcribe(TranscribeRequest(
          id: 'slow',
          locale: 'ja-JP',
          audio: PcmSegment(pcm16le: Uint8List(2), sampleRate: 16000),
          timeout: const Duration(milliseconds: 20),
        )),
        throwsA(isA<PcmAsrException>().having((e) => e.code, 'code', PcmAsrErrorCode.timeout)),
      );
      expect(calls.map((c) => c.method), ['transcribe', 'cancel']);
      expect(calls.last.arguments, {'id': 'slow'});
    });

    test('missing plugin reports unsupportedPlatform', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform.methodChannel, null);
      await expectLater(
        platform.support(locale: 'ja-JP'),
        throwsA(isA<PcmAsrException>().having((e) => e.code, 'code', PcmAsrErrorCode.unsupportedPlatform)),
      );
    });
  });
}
