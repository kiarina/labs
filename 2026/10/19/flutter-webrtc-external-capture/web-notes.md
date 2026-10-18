# Web external capture bridge

## Question and method

Can a browser keep acquiring video and PCM while WebRTC sends only during
selected intervals, then resume the same tracks? The bridge is shared between
the Flutter wrapper and an independent browser loopback harness. The harness
uses Chrome's fake camera and a deterministic 440 Hz, PCM16 little endian,
48 kHz mono signal. It tests the external input path; it does **not** test the
`record` plugin or physical camera/microphone capture.

Run from this lab:

```sh
python3 -m http.server 8876 --bind 127.0.0.1
# In another terminal (Node >= 22 and Chrome installed):
node tools/web/run_headless.mjs http://127.0.0.1:8876/tools/web/bridge_test.html 30
```

`CHROME` overrides the Chrome executable. The runner uses an isolated temporary
profile, fake camera permissions, autoplay permission, and removes its profile
on exit. Loopback uses host ICE only, with no external STUN/TURN service.

## Implementation

`app/web/capture_bridge.js` is loaded before Flutter's bootstrap script.
`app/lib/web_bridge.dart` wraps the resulting browser MediaStream with
`dart_webrtc`'s `MediaStreamWeb`. Its API matches the native bridge.

- `pushAudio` converts the PCM16 bytes to Float32 and feeds an AudioWorklet.
  `MediaStreamAudioDestinationNode` supplies the audio track. The queue is
  bounded to half a second; on overflow old queued audio is discarded. An
  underrun produces silence. This prototype assumes exactly 48 kHz mono and
  does not compensate independent capture/output clock drift.
- `pushVideo` converts tightly packed BGRA to RGBA, draws onto a canvas,
  and calls the canvas track's `requestFrame`.
- `startCamera` uses one `getUserMedia` video stream, reads a video element
  through a canvas at 15 fps, and provides BGRA frames to the application.
  This browser implementation replaces the camera plugin's missing Web image
  stream. The analyzer and output track receive the same frame bytes.
- Stopping transmission is done by `RTCRtpSender.replaceTrack(null)`, without
  disposing or recreating capture or output tracks. The same tracks are
  attached again to resume.

## Observations

`results/web-bridge.json` records the browser version, frame/sample counts,
receiver statistics and assertions. Chrome 155 on macOS passed all eight
assertions: capture continues while senders are detached; track IDs are stable;
video frames and decoded audio are received initially and after resumption;
audio and video received-byte counters stay unchanged during the measured
two-second detached interval after a one-second drain period.

The first harness iterations received RTP audio bytes but reported zero decoded
samples, energy and analyser RMS. Connecting only a Web Audio source did not
start WebRTC audio playout in this headless test. Creating an audio element
with the remote stream and awaiting `play()` resolved this; the final harness
checks decoded audio RMS, not merely RTP traffic. These failed iterations were
a receiver-consumption issue, not evidence of PCM injection failure.

`flutter analyze lib/web_bridge.dart` and `flutter build web` passed. The common
Flutter app also passed with synthetic inputs
(`results/web-flutter-synthetic.json`) and with `record.startStream` plus the
browser camera adapter (`results/web-flutter-capture.json`). Chrome's fake
camera/microphone devices were used in both browser acquisition APIs; no
physical devices were validated. In the latter run, send cycles decoded 89
and 90 video frames and measured audio RMS 0.0984 and 0.0961. All three idle
phases kept acquiring audio/video while injecting zero bytes/frames. The two
send cycles recreate peer connections but retain source capture and output
tracks; the standalone JS test separately verifies detaching/reattaching
senders on one connection. Both current tests clear the pending PCM queue
with `flush()` at transmission boundaries so a new session cannot receive
queued audio from an earlier phase.

To run the common Flutter app test:

```sh
cd app && flutter build web
python3 -m http.server 8877 --bind 127.0.0.1 --directory build/web
# In another terminal, from this lab:
node tools/web/run_headless.mjs http://127.0.0.1:8877/ 90
node tools/web/run_headless.mjs 'http://127.0.0.1:8877/?synthetic=true' 90
```

The Flutter page exports its report as `window.resultJson` for the runner.
Firefox, Safari, iOS browsers, actual device permissions,
AEC, audio route changes, long-running clock drift, background-tab throttling
and sustained CPU/battery use remain unverified. Camera frame copies and
canvas rendering add overhead; this is a feasibility prototype.
