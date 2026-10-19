# Independent capture observation criteria

The measured feasibility result is negative for the tested active candidates;
see the root README and results. This document defines what the observer can
establish; measured trials belong in their result files. An unavailable counter or missing event is not a zero.

## Claims and attribution

The requirement is that the same real `record` input remains active while native
Flutter WebRTC sends externally supplied media, without another microphone
initialization or capture start. Record capture is expected, so process ID alone
cannot distinguish it from WebRTC capture in the same application.

An ETW client initialization/start event is attributable to WebRTC when its
originating process, capture endpoint/stream identity and synchronous user stack
identify the SDK call chain. PDBs are unnecessary for module-level attribution:
loaded-module ranges permit `libwebrtc.dll + RVA` classification. Preserve module
identity, event timestamp, originating PID/TID, stream identity, endpoint direction,
HRESULT and the stack where available. Record attempts separately from successful
initializations and starts. A successful additional SDK capture initialization is
already a failure, even if it never starts or external-source RTP succeeds.

Audio service events can execute in a different process. Their emitting PID or
server-side stack must not be mistaken for the initiating client. Use an explicit
origin PID/stream correlation where supported; absence of an SDK frame on a
service-side stack does not establish absence of an SDK request. A known capture
event without sufficient attribution leaves the responsible component uncertain.

The observer must resolve the provider's actual event schema on the tested OS.
Do not assume a numeric stream-type value denotes capture without schema or
positive-control confirmation. Microphone privacy indicators, endpoint occupancy,
session counts and continuous PCM delivery alone cannot prove zero additional
capture. Multiple streams may share an audio session.

## WASAPI and DMO coverage

For a direct WASAPI route, capture-endpoint identity and
`GetService(IID_IAudioCaptureClient)` distinguish capture from ordinary render.
Loopback capture of a render endpoint must be classified separately. Successful
`GetService` requires a previously initialized stream; it is useful evidence but
does not cover every possible initialization attempt.

The pinned SDK also contains a Voice Capture DMO path. Merely creating
`CLSID_CWMAudioAEC` is not a microphone start: the SDK creates that object during
audio-device setup. In source mode, however, the DMO manages microphone devices
internally. Its capture initialization may therefore have a DMO/OS stack rather
than a direct SDK-to-WASAPI call chain. SDK-only `IAudioClient` observation must not
silently exclude this path.

Coverage must include DMO source-mode configuration and streaming allocation/data
processing, or OS capture events correlated back to that DMO instance. Relevant
calls are `AllocateStreamingResources` and `ProcessOutput`; allocation may also be
implicit when processing starts. DMO object creation counts alone prove neither
capture nor its absence. If the DMO route cannot be calibrated or excluded by
supported configuration and source evidence, a zero claim covering that route is
inconclusive.

## Calibration before negative conclusions

Use the same SDK asset, observer, OS and endpoint for controls and candidates:

1. Record-only control: identify the continuously active real recording stream.
2. Ordinary SDK microphone control: detect additional SDK capture initialization
   and start, with sufficient origin attribution.
3. DMO control, where available: demonstrate visibility of built-in-AEC capture.
   An unsupported or failed DMO control is not a successful negative control.
4. Candidate: retain record capture throughout off/on transitions and test actual
   external PCM/video RTP plus decoded reception. Muted, inactive or no-track
   phases alone do not satisfy the requirement.

Start observation before process/factory creation and retain it through teardown
to avoid missing eager or transient capture. Require zero lost events/buffers in
the trace statistics, correct provider enablement, complete interval boundaries
and successful controls. Zero losses are necessary, not sufficient: they do not
prove the provider emits every relevant operation or that attribution works.
Missing stacks, an unobserved startup interval, failed controls or uncovered
capture routes mean **inconclusive**, not success. A short control establishes
observer sensitivity for that route and interval, not general coverage of every
configuration or lifetime.

## Stock identity versus observer instrumentation

Verify the official download and the actual loaded SDK by hash and module path.
Absent custom audit exports establish only that those counters are unavailable.
They cannot be reported as zero. Do not modify the SDK binary, its behavior or COM
return values to make a candidate pass.

Prefer ETW because it permits observation without replacing SDK calls. If a
transparent IAT or per-instance COM observer is used as supplementary evidence,
label the run **runtime instrumented**, even when the on-disk DLL hash is stock.
Forward original arguments, HRESULTs, COM identity, references and lifecycle;
do not suppress requests, fabricate errors or substitute a device. Observe all
relevant activation/interface routes rather than assuming `CoCreateInstance`
alone covers them, especially DMO-internal capture. Compare instrumented and
uninstrumented media/lifecycle behavior to disclose observer perturbation. Such an
observer is a measurement tool, not a stock-SDK solution.

## References

- [Pinned Windows audio device implementation](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/modules/audio_device/win/audio_device_core_win.cc)
- [Microsoft: IAudioClient::GetService](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-getservice)
- [Microsoft: Voice Capture DSP](https://learn.microsoft.com/en-us/windows/win32/medfound/voicecapturedmo)
- [Microsoft: IAudioSessionControl2::GetProcessId](https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nf-audiopolicy-iaudiosessioncontrol2-getprocessid)
- [Microsoft: Event Tracing for Windows](https://learn.microsoft.com/en-us/windows/win32/etw/about-event-tracing)
