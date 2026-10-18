# macOS / iOS external media input

The standalone Objective-C plugin installs a PeerConnectionFactory using an
`RTCAudioDevice` before Dart's first flutter_webrtc operation. It registers
ordinary local audio/video tracks with flutter_webrtc's own registries. The
plugin must run before normal factory initialization; `prepare` rejects a
factory that is already initialized.

The custom device opens no physical capture device. A dedicated NSThread pulls
480 PCM16 mono samples every 10 ms from a 200 ms bounded queue and calls
`deliverRecordedData`. Underflow supplies silence; overflow drops oldest input.
`flush` clears the queue at transmission boundaries. The same thread pulls
`getPlayoutData` into a discarded buffer to drive remote decoding. Actual speaker
playback and echo cancellation are not implemented in this test device.
`record` owns physical microphone capture for the whole run. Its requested
format is 48 kHz / mono / PCM16, without AEC / NS / AGC.

BGRA input is copied into CVPixelBuffer, then submitted as RTCVideoFrame to
RTCVideoSource. Its timestamp comes from the application's monotonic clock.
This is an arrival-time approximation, not a calibrated A/V synchronization
scheme. There is no native WebRTC getUserMedia call in this application.

## Results

macOS 27.0.1 on an M1 Max laptop and iPadOS 27.0.1 on iPad Air (4th generation)
passed synthetic input and real camera/record input. The final real-input JSONs
are `results/macos-real.json` and `results/ios-real.json`. Each opens capture
once, traverses all five phases, receives video frames and nonzero PCM in both
send cycles, and passes `tools/verify_results.py`.

The initial macOS app inherited capture-only sandbox entitlements and lacked
network client/server entitlements. It could create tracks and produce silence
callbacks but received no RTP or video frames. Both failed JSONs are retained
as `*-no-network-entitlement.json`; the app now includes both network
entitlements. This is why receiver callbacks alone are insufficient evidence.

## Build and run

Use the Swift Package Manager setup supplied by Flutter 3.47.2. The plugin's
Package.swift depends on the sibling local flutter_webrtc package materialized
by `tools/prepare.py`. Both Darwin source copies must remain identical.

```sh
python3 tools/prepare.py
cd app
flutter pub get
flutter build macos --release
flutter build ios --release --no-codesign
```

For real iOS installation configure your own development team/signing, sign the
app and install it through Xcode or devicectl. Test parameters are loaded from
`tmp/external_config.json` in the application's data container, and results are
written to `tmp/external_result.json`. `tmp/external_status.txt` identifies a
permission or capture stage if a run has not completed. Allow microphone and
camera permissions and keep the device unlocked/foreground during the test.

The custom ADM remains owned by the process's factory until process exit.
This feasibility app does not restore flutter_webrtc's normal audio device.
