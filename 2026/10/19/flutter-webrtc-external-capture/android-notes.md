# Android external capture bridge

## Question and method

Can the application keep `camera` and `record` open, then route their existing
BGRA frames and PCM16 chunks into WebRTC only while an external track exists?
The bridge creates a `VideoSource` plus a regular `AudioSource`, registers their
tracks in flutter_webrtc's local registries, and supplies the shared ADM input
from a bounded PCM queue. Local loopback receiver counters and media taps are the
end-to-end acceptance test; compilation alone does not prove media delivery.

## Implementation

The pinned `flutter_webrtc 1.6.2+hotfix.4` depends on
`io.github.webrtc-sdk:android:150.7871.01`. Inspection of that exact AAR with
`javap` confirmed these public entry points:

- `JavaAudioDeviceModule.Builder.setAudioBufferCallback(AudioBufferCallback)`
- `JavaAudioDeviceModule.setAudioRecordEnabled(false)`
- `AudioBufferCallback.onBuffer(ByteBuffer, format, channels, rate, bytesRead, timestamp)`

The callback runs before `nativeDataIsRecorded`. Disabling AudioRecord leaves
this callback running without a physical capture device; the bridge paces it at
10 ms and supplies silence on underflow. PCM input is little-endian signed
16-bit, 48 kHz, mono. The queue holds at most 200 ms and discards oldest input
on overflow. WebRTC's physical microphone path stays disabled for the whole
lab process, including between external-track sessions.

`pushVideo` converts packed BGRA to I420 and calls
`VideoSource.getCapturerObserver().onFrameCaptured`. Chroma uses 2x2 averaging.
`timestampUs` is converted to nanoseconds. Rotation must already be reflected
in the supplied pixels.

Run `python3 patches/android/apply.py vendor/flutter_webrtc` immediately after
copying the pristine pinned package. The script checks unique upstream anchors
and reapplies the bridge source idempotently. It only changes the lab-local copy.

## Limits

Only one external stream and one shared external audio feed are supported.
`getUserMedia` audio must not be mixed with this lab's external audio mode.
This bypasses Android's hardware microphone AEC and noise suppressor; it does
not establish that arbitrary external PCM receives suitable echo cancellation.
The Java BGRA converter and MethodChannel frame copies are a correctness probe,
not an optimized production camera path. Retaining a track while withholding
frames is not the same as disconnecting its sender: the ADM emits silence when
no input is queued. The Dart gate must remove/replace the sender to stop sending.

## Verification status

AAR API and callback ordering were inspected locally. Android compile and
physical-device loopback results are recorded below when run.

The patched plugin passed
`./gradlew :flutter_webrtc:compileDebugJavaWithJavac --console=plain` under
Android Studio's bundled JBR, Gradle 9.3.1 and Android SDK 36. The host's default
JDK 11 cannot read the SDK's Java 17 class files, so use Flutter's configured JDK
or Android Studio's JBR. This compiled the real patched plugin, including the
factory hook and MethodChannel registration. It did not yet exercise capture or
RTP on a device.

On a Pixel 6 running Android 17, the first real-device trial found an important
integration failure: `record`'s default `AudioInterruptionMode.pause` paused PCM
delivery when WebRTC's AudioSwitch acquired audio focus. Camera frames continued,
and the receiver audio tap still emitted silence. The original result is retained
in `results/android-real-interruption-pause.json`. The source produced 291,840
bytes in idle-before, then zero throughout both send intervals and subsequent
idles. This is why receiver PCM callback counts alone are insufficient evidence.

The lab now configures `AudioInterruptionMode.none` and requires source audio and
injected audio to advance during send. Synthetic trials additionally require
receiver RMS > 0.05. This opt-out concerns the recorder's interruption policy;
it does not prove every Android device keeps recording through a mode/route change.

With `AudioInterruptionMode.none`, the same Pixel 6 / Android 17 real-capture
trial passed all five phases. Both camera and microphone were started once.

| Phase | Source video | Source PCM bytes | Injected PCM bytes | Receiver video | Receiver PCM bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| idle-before | 84 | 284160 | 0 | — | — |
| send-1 | 189 | 625920 | 610560 | 178 | 684480 |
| idle-after-1 | 90 | 276480 | 0 | — | — |
| send-2 | 191 | 610560 | 610560 | 184 | 674880 |
| idle-after-2 | 91 | 272640 | 0 | — | — |

Receiver RMS was 0.1244 and 0.2145. In send-1, the Dart backpressure guard dropped
15,360 PCM bytes while an earlier MethodChannel call was busy; no video frames
were dropped by that guard. This proves capture continuity and media delivery
for this device, not production audio quality or echo cancellation. Raw evidence:
`results/android-real-before-flush.json`.

The synthetic-input trial also passed: receiver video 152/159 frames and PCM
710,400/703,680 bytes, RMS 0.0705/0.1080. The sine input met the strengthened RMS
threshold, and every idle phase had zero injection. Evidence:
`results/android-synthetic.json`.

`flush` clears the bounded PCM queue without resetting the ADM's 10 ms cadence.
Call it at the sender gate boundary after pending pushes finish, so an old PCM
tail cannot leak into the next session. The first successful trials above
preceded addition of this explicit flush boundary.

The final build, including explicit flush boundaries, also passed on the same
device (`results/android-real.json`). Idle phases kept 84/90/92 source video
frames and 288,000/272,640/276,480 source PCM bytes, with zero injection. During
send-1/send-2 the remote taps delivered 183/183 video frames and
695,040/672,000 PCM bytes, RMS 0.1486/0.1899. Each send phase dropped 3,840 PCM
bytes under the Dart single-inflight backpressure guard.

Independent receiver `inbound-rtp` stats confirm actual network delivery:
audio packets received 356/343, audio energy 1.9374/2.6765, and video frames
decoded 184/183. The Android remote taps explicitly resolve `getRemoteTrack`,
so equal local and remote track IDs cannot silently select the local input.
The remote video tap count and decoder count can differ by one because polling
and the stats snapshot occur at slightly different instants.
