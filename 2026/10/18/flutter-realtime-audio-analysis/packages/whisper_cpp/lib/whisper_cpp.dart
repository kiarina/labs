/// Local Whisper speech recognition with whisper.cpp.
///
/// Native platforms (macOS, iOS, Android, Windows) use dart:ffi
/// (`src/whisper_native.dart`); the web uses a WebAssembly build
/// (`src/whisper_web.dart`). Both expose the same `WhisperEngine` API.
library;

export 'src/whisper_types.dart';
export 'src/whisper_native.dart' if (dart.library.js_interop) 'src/whisper_web.dart';
