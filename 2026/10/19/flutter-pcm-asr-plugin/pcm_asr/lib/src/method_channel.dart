import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_interface.dart';
import 'types.dart';

/// Method-channel implementation shared by the native platforms.
///
/// Channel: `pcm_asr`. Methods: `support`, `prepare`, `transcribe`, `cancel`,
/// `dispose`. Arguments and replies are plain maps so every platform can speak
/// it without generated code.
class MethodChannelPcmAsr extends PcmAsrPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('pcm_asr');

  @override
  Future<RecognitionSupport> support({required String locale}) async {
    final map = await _invoke('support', {'locale': locale});
    return RecognitionSupport(
      engine: map['engine'] as String? ?? 'none',
      supported: map['supported'] as bool? ?? false,
      acceptsExternalPcm: map['accepts_external_pcm'] as bool? ?? false,
      onDevice: map['on_device'] as bool? ?? false,
      modelState: ModelState.values.byName(map['model_state'] as String? ?? 'unknown'),
      locale: map['locale'] as String?,
      sampleRates: [for (final r in (map['sample_rates'] as List?) ?? const []) r as int],
      needsNetworkForModel: map['needs_network_for_model'] as bool? ?? false,
      reason: map['reason'] as String?,
    );
  }

  @override
  Future<void> prepare({required String locale}) async {
    await _invoke('prepare', {'locale': locale});
  }

  @override
  Future<TranscribeResult> transcribe(TranscribeRequest request) async {
    final started = DateTime.now();
    final call = _invoke('transcribe', {
      'id': request.id,
      'locale': request.locale,
      'pcm16le': request.audio.pcm16le,
      'sample_rate': request.audio.sampleRate,
      'channels': request.audio.channels,
    });
    Map<Object?, Object?> map;
    try {
      map = await call.timeout(request.timeout);
    } on TimeoutException {
      await cancel(request.id);
      throw PcmAsrException(
        PcmAsrErrorCode.timeout,
        'No final result within ${request.timeout.inMilliseconds} ms',
      );
    }
    final elapsedMs = map['elapsed_ms'];
    return TranscribeResult(
      id: map['id'] as String? ?? request.id,
      text: map['text'] as String? ?? '',
      engine: map['engine'] as String? ?? 'unknown',
      locale: map['locale'] as String? ?? request.locale,
      elapsed: elapsedMs is num
          ? Duration(microseconds: (elapsedMs * 1000).round())
          : DateTime.now().difference(started),
      ranges: [
        for (final r in (map['ranges'] as List?) ?? const [])
          TranscribedRange(
            text: (r as Map)['text'] as String,
            start: (r['start'] as num).toDouble(),
            end: (r['end'] as num).toDouble(),
          ),
      ],
    );
  }

  @override
  Future<void> cancel(String id) async {
    await _invoke('cancel', {'id': id});
  }

  @override
  Future<void> dispose() async {
    await _invoke('dispose', const {});
  }

  Future<Map<Object?, Object?>> _invoke(String method, Map<String, Object?> args) async {
    try {
      final reply = await methodChannel.invokeMethod<Map<Object?, Object?>>(method, args);
      return reply ?? const {};
    } on PlatformException catch (e) {
      throw PcmAsrException(_code(e.code), e.message ?? e.code, details: e.details);
    } on MissingPluginException {
      throw const PcmAsrException(
        PcmAsrErrorCode.unsupportedPlatform,
        'pcm_asr has no implementation on this platform',
      );
    }
  }

  static PcmAsrErrorCode _code(String code) {
    for (final value in PcmAsrErrorCode.values) {
      if (value.name == code) return value;
    }
    return PcmAsrErrorCode.engineFailure;
  }
}
