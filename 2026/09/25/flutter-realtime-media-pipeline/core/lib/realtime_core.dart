/// Pure Dart core of the realtime media pipeline lab.
///
/// Nothing under `lib/` may import Flutter, flutter_webrtc, `dart:html`,
/// `dart:js_interop`, `dart:ffi`, or `dart:io`; `test/architecture_test.dart`
/// enforces this, and this package does not depend on Flutter at all.
library;

export 'src/adapters/webrtc_stats.dart';
export 'src/application/codec.dart';
export 'src/application/intake.dart';
export 'src/application/pipeline.dart';
export 'src/application/processor.dart';
export 'src/application/responder.dart';
export 'src/application/session.dart';
export 'src/domain/action.dart';
export 'src/domain/media.dart';
export 'src/domain/support.dart';
export 'src/local/local_operation.dart';
export 'src/mock/in_memory_signaling.dart';
export 'src/mock/mock_action_transport.dart';
export 'src/mock/mock_media_source.dart';
