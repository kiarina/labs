/// Real-time audio analysis ported from kiarina-agi-audio: VAD, speaker
/// change detection, ASR (pluggable), speaker and sound embeddings, sound
/// tagging, and a bounded store of what was heard.
library;

export 'src/analyzer.dart';
export 'src/asr/asr.dart';
export 'src/consumer/audio_window_buffer.dart';
export 'src/consumer/consumers.dart';
export 'src/consumer/events.dart';
export 'src/dsp/pcm.dart';
export 'src/embedding/clap.dart';
export 'src/embedding/ecapa.dart';
export 'src/hearing_store.dart';
export 'src/models/catalog.dart';
export 'src/models/model_file.dart';
export 'src/models/model_store_io.dart' if (dart.library.js_interop) 'src/models/model_store_web.dart';
export 'src/onnx.dart';
export 'src/onnx_backend_io.dart' if (dart.library.js_interop) 'src/onnx_backend_web.dart';
export 'src/scd/pyannote_scd.dart';
export 'src/scd/speaker_change_detector.dart';
export 'src/tagging/yamnet.dart';
export 'src/vad/silero_vad.dart';
export 'src/vad/voice_detector.dart';
