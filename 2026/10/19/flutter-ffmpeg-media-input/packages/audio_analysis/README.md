# Audio analysis subset

This lab owns a copy of the ONNX backends, PCM helpers and Silero VAD/voice detector from the 2026-10-18 audio analysis lab. The copy was made from labs commit 476bb018bde6e2227f89766729d97c48ffc1250b. No sibling lab is imported at runtime. Other ASR, speaker and ambient models are outside this experiment; they were tested in the preceding lab.

The public entry point is `lib/audio_analysis.dart`. Call `defaultOnnxBackend().load(location)`, create `SileroVad` or `VoiceDetector`, and close the ONNX model after use. Model weights are prepared by the parent lab, not published with this package. Tests for streaming boundaries are in the parent app.
