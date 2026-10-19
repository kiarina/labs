# Optional record_windows RAW stream fork

Run `python tools/prepare_record.py` to materialize the pinned 2.3.0 package under
`vendor/record_windows`. The parent application must override that package path.
The patch is idempotent and validates unique source anchors; the shared pub cache
is never changed. The downloaded archive hash is retained in generated
`LAB_SOURCE.json`.

With process environment `AEC_RECORD_RAW=1`, `record.startStream` accepts only
PCM16 mono 48 kHz with an explicit device ID. It stops any previous acquisition,
branches before Media Foundation creation, and starts one shared-mode WASAPI
capture worker for that endpoint. `IAudioClient2::SetClientProperties` requests
`AUDCLNT_STREAMOPTIONS_RAW` with AudioCategory_Other. Failure returns its HRESULT
through the existing startStream error path; there is no Media Foundation
fallback. Without the exact environment value `1`, the original MF path remains.
No global endpoint, volume or effect property is changed.

The native mix format is converted/downmixed to mono and linearly resampled to
48 kHz if necessary; PCM16 packets contain 480 samples. Float32 and signed
16/24/32-bit native formats are supported. The existing chunk callback posts
through `PlatformThread` into the usual record event channel. Stop/dispose joins
the capture thread before clearing configuration or callbacks. This experimental
branch does not support pause/resume (E_NOTIMPL), file recording, AAC, amplitude
tracking, or output rates/channels other than mono48k.

`RecordRawAudit(int)` is exported from the plugin DLL. Indices are cumulative:
0 RAW requests, 1 RAW properties accepted, 2 capture starts, 3 native captured
frames, 4 last HRESULT as uint32, 5 MF capture creation requests, 6 currently
active RAW captures. A requested RAW run must show requests/properties/starts=1,
frames>0, MF requests=0 and HRESULT=0; after disposal active captures must be0.
Export absence is not a zero counter. A runtime capture failure is preserved in
index4 and must fail the result even if startStream initially succeeded.

RAW is a per-stream Windows request. It does not promise that microphone firmware
or physical processing is bypassed. Driver support and actual stream continuity
must be measured before attributing any AEC difference to RAW.
