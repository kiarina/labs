# Third-party sources

- Standalone AEC3: Enaium/webrtc-aec3 commit
  2cec2f52e26646f93bd2d5498bbabf59cba18da9, BSD-3-Clause.
  `tools/prepare_aec.py` downloads it into ignored vendor/, renames private
  namespaces to avoid WebRTC/Abseil symbol collisions and applies the recorded
  MSVC portability changes. Preserve upstream licenses/notices in binary
  distribution. Its underlying WebRTC revision is unspecified; it is not the
  same source revision claim as the transport SDK.
- `record_windows`2.3.0: fetched from pub.dev with fixed archive SHA256 and an
  explicit lab-local RAW patch. The package's upstream license is kept in the
  ignored prepared directory. Shared pub cache source is not modified.
- Capture/fork/library dependencies and their exact resolutions are recorded in
  app/pubspec.yaml and app/pubspec.lock. This lab does not redistribute their
  native binaries or private captures. The fork SDK release carries its own
  source manifests and license notices.
- The capture/DSP fixture, the AEC engine wrapper, the record_windows patch and the
  remote-track lookup (media_taps style) are adapted from the linked predecessor
  labs into this directory, with no runtime imports from them.
- `@openai/codex` 0.163.0 is installed by npm into ignored work/ for the control
  server; it is not redistributed.
