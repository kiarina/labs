# Windows media taps for candidate validation

This lab owns a Windows-scoped copy of the preceding experiment's media-tap
plugin. It attaches audio/video sinks to native flutter_webrtc tracks and polls
bounded queues for PCM/frame counters. Compile it against this lab's matching
Flutter plugin and SDK headers/import library. It does not independently prove
OS microphone ownership; the separate loss-free ETW controls do that.

The lab measures decoded frame/sample counts and aggregate RMS. It does not
publish microphone PCM or establish speaker/AEC quality. The common Dart API
and conditional stubs are retained, but only the Windows plugin is registered
and validated here. The predecessor owns its other-platform implementations.
