# Independent input observation

Build input_observer.mm as a debug-only preload dylib. It interposes public
AudioUnitSetProperty/AudioOutputUnitStart calls and records AVAudioEngine inputNode
access with stacks, without recording PCM or changing results. The instrumented
process must not use a hardened configuration that blocks insertion. Confirm the
installed marker before interpreting an empty trace. Object identities and raw
stacks stay private; publish only module-attributed counts.

Run ownership_control.dart with a default factory as a positive sensitivity
control. Its ordinary getUserMedia(audio:true) must show SDK input enable/start
before zero SDK input in the external-only process is meaningful. AVAudioEngine
inputNode alone is supplementary because native SDKs can use AudioUnits directly.

```sh
mkdir -p build
clang++ -std=c++17 -dynamiclib tools/macos/input_observer.mm \
  -o build/input_observer.dylib -framework Foundation \
  -framework AVFoundation -framework AudioToolbox -framework CoreAudio
DYLD_INSERT_LIBRARIES="$PWD/build/input_observer.dylib" \
  AEC_SDK_MIC_CONTROL=1 AEC_PEER=http://127.0.0.1:18796 \
  app/build/macos/Build/Products/Debug/external_media_example.app/Contents/MacOS/external_media_example \
  > build/sdk-positive.log 2>&1
```

Use the same observer with the ordinary physical trial (unset
AEC_SDK_MIC_CONTROL) and compare input ownership. The SDK control negotiates with
the silent independent peer and runs8seconds. Creating a track alone is not a
valid start-recording sensitivity control. Do not rebuild/overwrite a loaded
observer image while a run is active. A failed/absent observer is not zero-input
evidence. The native fixture stays inside its normal camera/audio sandbox rights.
