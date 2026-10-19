# Windows normal native playout AEC and double-talk

Continuous record input, normal native WebRTC speaker playback and zero additional SDK microphone acquisition coexist in this fixture. **On the requested DualSense microphone, baseline AEC passed participant listening:** clarity4/5, no missing words, no pumping and no echo in human-6. Fixed8x low-input conditioning is not used for this input. This is limited listening acceptance, not a full zero-clipping or general hardware acceptance: the live AEC output still contained full-scale samples.

Windows video is explicitly synthetic throughout this fixture. This is not physical camera validation or a five-platform result. The candidate SDK from core[#314](https://github.com/webrtc-sdk/webrtc/pull/314)/wrapper[#158](https://github.com/webrtc-sdk/libwebrtc/pull/158) stays unchanged; this is not an official stock-SDK result.

## Architecture

One record RAW WASAPI capture continuously supplies PCM. Device-free standalone AEC3 processes it continuously, including while transmission is off. The external track receives only the chosen processed output when sending is enabled. Normal native WebRTC renders far speech to the selected speaker. A separate WASAPI **render-loopback** client on that same endpoint supplies actual playback reference; it does not open a microphone or own a speaker. An independent peer sends far speech and saves decoded near speech without playing it back.

Select output through the public API after media PeerConnection creation, before negotiation. The inherited diagnostic native-playout-disable path is unused. There is no custom SDK mixer pull, second speaker clock or custom SDK recording audit export in these measurements. Record's own RAW counters supplement independent ETW; render-loopback capture is classified separately from physical microphone capture.

## Measurements

| Trial | Observation | Decision |
|---|---|---|
| First positive-control attempt | Missing expected-hash environment variable rejected startup before capture | Failed launch, not zero-capture evidence |
| Positive-control2 | SDK microphone events observed, SDK source APM not explicitly off | Supplemental only |
| Positive-control3 | Same transport APM-off policy; record RAW1, SDK physical microphone clients2 over process lifetime, lost events/buffers0 | Primary observer sensitivity control; not a concurrency claim |
| synthetic-1 | SDK microphone0, RAW1, near retention passes; warmup clipping/transient and poor reference calibration | Echo quality inconclusive |
| human-1 | SDK microphone0; identifiable far-only coherent reduction19.50/21.64dB | Participant heard no conversation; wrong desired microphone, not human success |
| human-2, selected Realtek | Voice heard, no pumping/echo reported; possible double-talk voice loss | Not accepted; listening gain32, normal-volume usability untested |
| synthetic-low-2 | Same live input/reference into baseline and conditioning8; SDK microphone0, RAW1, lost events/buffers0, unchanged endpoint volumes | Known-near retention improved; physical echo coherence still insufficient |
| human-3 | Initial microphone-check speech vs quiet difference-0.47dB, aborted before DT | No completed human repeat; preserved failure |
| human-4 | Completed human protocol on DualSense; raw speech about-7dBFS, near-full-scale metric1766 samples, conditioning overrange1,624,693 samples | Outside low-input applicability; not a human fix acceptance |
| human-5 | DualSense/baseline; strong input during both speech and quiet; contrast3.33dB | Aborted before DT; calibration procedure/error text corrected |
| human-6 | Explicit DualSense/baseline; stop-voice confirmation, quiet-tail contrast16.19dB; participant clarity4, no loss/pumping/echo | Limited listening acceptance; AEC output full-scale samples remain |

See [ownership control](results/positive-control-3-ownership.json), [human-2 assessment](results/human-2-assessment.json), [dropout localization](results/human-2-dropouts.json), [new ownership](results/synthetic-low-2-ownership.json) and [paired near windows](results/synthetic-low-2-near-windows.json). PCM/ETL stay private; results contain metrics and hashes only.

## Dropout cause and candidate

In human-2,100ms windows with raw input above-65dBFS showed raw-to-AEC ratios as low as-17.95dB in DT1 and-25.41dB in DT2. There were7/14 windows below-6dB. Near-only and recovery minima were about-.47/-.43dB, with no such windows. The decoder comparison found no extra >12dB energy-loss windows in the analyzed voice-active interiors; locally aligned median correlations were approximately.97. This makes AEC over-suppression a stronger explanation than receiver-only loss. It does not rule out capture timing: the original maximum callback gap104.568ms lacked its position. Raw-to-output ratios are not isolated human-near gain.

The original listening file also joined two6second clips. Its edit at6seconds can sound like a missing word. Subsequent listening must use the separate continuous DT clips.

The opt-in `conditioned` candidate multiplies low capture input by8 before baseline AEC3, then divides output by8. It retains the baseline internal delay estimator and never mixes raw input into the result or bypasses AEC. Exploratory replay favored this over near-detector threshold tuning and the prior long-filter candidate. Original event order was unavailable, so that exploration approximated cadence and is not a byte-identical replay claim. The evidence supports a level-sensitive AEC problem; the exact internal threshold responsible has not been isolated.

A **new** physical-far/known-capture-only-near trial used peak450 near speech to approximate the low input level. All profiles received identical input/reference and processing order:

| Active100ms known-near metric | Baseline DT1 / DT2 | Conditioning8 DT1 / DT2 |
|---|---|---|
| Minimum signed near projection gain | -15.99 /-27.86dB | -2.26 /-.96dB |
| Windows below-6dB | 11/44 /7/41 | 0/44 /0/41 |
| Longest consecutive run below-6dB | 400 /200ms | 0 /0ms |

The2second sender-off DT interval also kept acquisition/DSP running: baseline minimum-23.14dB, candidate-4.82dB. Candidate overrange0, DSP errors0, maximum callback gap34.793ms. Reference calibration failed, so far-only echo non-regression is **inconclusive**, not a pass. A weak echo that is inaudible does not establish AEC causality.

A serialized R/C event log now makes the live processing reproducible: Windows replay of baseline **and** candidate was byte-identical to their recorded outputs ([hash verification](results/event-replay-synthetic-low-2.json)). This is stronger paired evidence than approximate replay.

The [low-input digital fixture](results/digital-conditioned-low-input.json) passes the original thresholds. The [normal-input digital fixture](results/digital-conditioned-gain8.json) fails DT near retention: fixed8x conditioning is **not a general input-level solution**. Baseline remains the default. Opt-in conditioning requires low-level headroom (`conditionedOverrangeSamples==0`), fresh listening and echo checks. It is not AGC; output loudness remains low. See [investigation protocol and limitations](docs/dropout-investigation.md).

## Evaluation and reproduction

Predeclared thresholds: far-only identifiable render-coherent reduction>=15dB; synthetic near correlation>=.95 and gain within+-3dB; DT known-near gain>=-6dB and identifiable echo reduction>=6dB. Weak raw/reference coherence is inconclusive. Real human near additionally requires participant listening, clarity>=4/5, no repeated word loss and echo none/slight. Real near has no independent clean reference. Short-window retention was added for the dropout investigation before the new candidate trial; older average-gain passes do not establish absence of missing syllables.

[Run/build/analysis](docs/run.md) describes input, versions, candidate staging, independent peer, observer, microphone-check and cleanup. Standalone AEC extraction is Enaium/webrtc-aec3@2cec2f52e26646f93bd2d5498bbabf59cba18da9, BSD-3-Clause, with private namespaces and MSVC portability fixes. Its underlying WebRTC revision is unspecified and is not asserted equal to the transport SDK. Pins intentionally isolate this comparison; no paid service is used.

Predecessors: [normal speaker playback](../flutter-windows-upstream-external-input/upstream/playout/README.md) and [owned-render AEC/human trial](../flutter-windows-aec-doubletalk/HUMAN.md). Source copies are owned here; no cross-lab imports or implicit synchronization. [Investigation patch](patches/dropout-investigation.patch) records the changes from the human-2 DSP/application source. Five platforms, real Windows camera, other microphone levels, Bluetooth, long sessions, robust acoustic DT echo separation and ordinary received loudness remain unverified.

## Human-4 applicability failure

The next human repeat selected a DualSense microphone rather than the previous low-level Realtek input. Mic-check SNR11.44dB passed, but near speech was about-7dBFS and exceeded fixed8x headroom. Conditioning attenuated even near-only speech by about12dB; active DT100ms raw-to-output ratios reached-51/-54dB. This confirms the low-input candidate must not be applied generally. Raw clipping1766 samples also prevents a clean near-fidelity claim. See [assessment](results/human-4-assessment.json) and [measurements](results/human-4.json).

Independent ETW still found record RAW1, SDK microphone0, normal speaker1 and render-loopback1, lost events/buffers0. Endpoint volumes were unchanged and maximum callback gap15.347ms. Identifiable far-only coherent reduction passed for baseline and conditioned, which does not compensate for lost near speech. An application guard now rejects conditioned human trials after mic-check if any nominal8x input overrange was observed, before the long protocol. Human mode also requires explicit microphone selection on every run unless an input ID was explicitly supplied; it cannot silently start on a saved or fallback device. These guard/UI changes were Windows-release build checked; a fresh runtime trial is still required. The participant confirmed DualSense as the desired microphone; human-6 therefore sends baseline, not fixed8x conditioning.

## Requested DualSense baseline result

The participant explicitly chose DualSense. Human-5 aborted with speech-7.02dBFS versus quiet-10.35dBFS: the old error incorrectly said speech was absent. Recorded quiet stayed loud throughout; whether this was continuing speech or ambient/handling sound was not established. The updated procedure asks the participant to stop speaking and press a quiet-measurement button, measures8seconds and uses its final4seconds. The6dB contrast criterion is unchanged. Baseline and other DSP streams continue throughout this dialog; capture is never reopened.

Human-6 passed that check (speech-8.38, quiet-24.58dBFS, contrast16.19dB), completed the protocol and sent **baseline**. Independent ETW again found RAW1/SDK microphone0/render-loopback1/native speaker1, lost events/buffers0, clean record shutdown and unchanged endpoint volume/mute. Maximum callback gap14.787ms. Identifiable far-only coherent reduction was38.82/25.65dB. DT echo is not independently source-separated.

The participant listened to separate continuous decoded DT clips and near/recovery clips: clarity4/5, no missing words, acceptable/stable volume and no echo. Common listening gain was0.89997 (slight attenuation, no amplification). See [assessment](results/human-6-assessment.json), [ownership](results/human-6-ownership.json), [analysis](results/human-6.json) and [delivery diagnostics](results/human-6-dropouts.json). This establishes a useful short-run result for this microphone/setup, not other hardware or a causal comparison across different microphones.

A limitation remains: baseline output had1103 exactly full-scale samples. The analyzer's historical rawClippedSamples/clipSamples metric counts absolute values>=32700, so it includes near-full-scale samples and must not be read as proof of ADC saturation. A same-DLL/same-event-order **offline** replay at capture gain0.5, with no output gain restoration, reduced exactly full-scale output samples to0. Output is about6dB quieter. This [headroom replay](results/human-6-headroom-replay.json) was not sent in the live trial and has no decoded-receiver listening or far-echo non-regression validation; it is not adopted for live sending. The strict all-criteria acceptance remains false due to the live output limit, despite the positive participant listening.
