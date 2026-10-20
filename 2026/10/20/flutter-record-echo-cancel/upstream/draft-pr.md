# Draft: Pull Request to llfbandit/record (base: main)

Title:

fix(darwin): Keep audio when voice processing gives discrete channels on macOS

Body:

---

On macOS, `startStream` with `echoCancel: true` gives a stream where every sample is 0. I hit this with `record` 7.1.2 (`record_macos` 2.1.1) on a MacBook Pro M1 Max, macOS 27.0.1, built-in mic.

With voice processing on, the input node gives `9 ch, 48000 Hz, Float32, deinterleaved`, and the channel layout is `kAudioChannelLayoutTag_DiscreteInOrder | 9`. The tap does get sound. But an `AVAudioConverter` from that format to mono Int16 comes with `channelMap == [-1]`, so no input channel feeds the output and it converts to silence. From a plain stereo format the default map is `[0]`, which is why normal mics are fine.

#523 fixed this by copying the first channel before converting, and #586 later removed that copy to keep stereo, so 2.1.x has it again. `main` still converts from the tap format directly in `AudioStreamProcessor` and `AudioFileOutput`, so I think it's the same there.

This PR fills the unmapped output channels with input channel 0 in `AVAudioConverter.make`. Channel 0 is the processed one (that's what #523 relied on, and echo cancellation works with it). Normal mics never get a `-1` in the map, so nothing changes for them.

I added a test that runs a 9-channel discrete buffer through `AudioStreamProcessor`. It needs no mic, fails without the change, and the 71 macOS tests in `RunnerTests` pass with it. I didn't run the iOS tests; on my iPad the voice processing input is mono, so the map has no `-1` there.

If you want to see it with a real mic, this small Swift file reproduces it without Flutter (it prints the converted peak with and without `channelMap = [0]`):
https://github.com/kiarina/labs/blob/main/2026/10/20/flutter-record-echo-cancel/upstream/vp_convert_probe.swift

```
voiceProcessing=true input=<AVAudioFormat:  9 ch,  48000 Hz, Float32, deinterleaved>
tap ch0 peak             0.0624
A convert whole buffer   0.0000
B channelMap = [0]       0.0397
C copy ch0, then convert 0.0397
```

I've only checked the fix itself on `main` through the probe and the unit test. With the first-channel copy applied to 2.1.1 in my app, echo cancellation works on the real device (details in the lab: https://github.com/kiarina/labs/tree/main/2026/10/20/flutter-record-echo-cancel).

One question: would you like a fix for the published `record_macos` 2.1.x too, or is it fine to wait for `record_darwin`? I can send a separate PR against the 2.1.1 code if that helps.

---

## Notes for the owner (not part of the body)

- Base is `main` at `334256c` (2026-10-20). The diff is `record_darwin-channel-map.diff` (5 lines + a 29-line test).
- Before sending, the lab files (`upstream/`) need to be committed and pushed to kiarina/labs so the links work.
- The author said in #630 that the darwin code is mid-rewrite and big PRs are hard to merge; this one touches one function.
- Alternative: open an issue only (same text without "This PR ..." and the test paragraph, ending with an offer to send the PR).
