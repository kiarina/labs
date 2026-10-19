import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel.dart';
import 'types.dart';

/// The contract every platform implementation fulfils.
abstract class PcmAsrPlatform extends PlatformInterface {
  PcmAsrPlatform() : super(token: _token);

  static final Object _token = Object();

  static PcmAsrPlatform _instance = MethodChannelPcmAsr();

  static PcmAsrPlatform get instance => _instance;

  static set instance(PcmAsrPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<RecognitionSupport> support({required String locale}) {
    throw UnimplementedError('support() has not been implemented.');
  }

  Future<void> prepare({required String locale}) {
    throw UnimplementedError('prepare() has not been implemented.');
  }

  Future<TranscribeResult> transcribe(TranscribeRequest request) {
    throw UnimplementedError('transcribe() has not been implemented.');
  }

  Future<void> cancel(String id) {
    throw UnimplementedError('cancel() has not been implemented.');
  }

  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
