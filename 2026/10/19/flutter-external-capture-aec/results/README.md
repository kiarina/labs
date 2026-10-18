# Retained evidence

Raw microphone PCM stays outside Git. Reports include source/capture counters,
conditions, metrics and failures. A transport pass does not imply acoustic quality
or human-speech preservation. The physical near fixtures are capture-only synthesis.

| Report | Evidence type |
|---|---|
| [android-acoustic-blocking-render.json](android-acoustic-blocking-render.json) | Physical run / derived metrics; see platform limitations |
| [android-acoustic-high-output.json](android-acoustic-high-output.json) | Physical run / derived metrics; see platform limitations |
| [android-acoustic-low-output.json](android-acoustic-low-output.json) | Physical run / derived metrics; see platform limitations |
| [android-acoustic-trace.json](android-acoustic-trace.json) | Physical run / derived metrics; see platform limitations |
| [android-gate-keyguard-locked.json](android-gate-keyguard-locked.json) | Failed startup/trace/lock trial; retained as failure |
| [android-gate-os-frozen.json](android-gate-os-frozen.json) | Failed startup/trace/lock trial; retained as failure |
| [ios-acoustic.json](ios-acoustic.json) | Physical run / derived metrics; see platform limitations |
| [ios-rtc-integrated.json](ios-rtc-integrated.json) | Physical run / derived metrics; see platform limitations |
| [macos-acoustic.json](macos-acoustic.json) | Physical run / derived metrics; see platform limitations |
| [macos-digital.json](macos-digital.json) | Digital fixture (no physical acoustic claim) |
| [macos-rtc-integrated.json](macos-rtc-integrated.json) | Physical run / derived metrics; see platform limitations |
| [macos-startup-permission-timeout.json](macos-startup-permission-timeout.json) | Failed startup/trace/lock trial; retained as failure |
| [web-acoustic-analysis.json](web-acoustic-analysis.json) | Physical run / derived metrics; see platform limitations |
| [web-browser-digital.json](web-browser-digital.json) | Digital fixture (no physical acoustic claim) |
| [web-digital-coarse-alignment.json](web-digital-coarse-alignment.json) | Digital fixture (no physical acoustic claim) |
| [web-digital.json](web-digital.json) | Digital fixture (no physical acoustic claim) |
| [web-flutter-fake-acoustic-probe.json](web-flutter-fake-acoustic-probe.json) | Fake-device transport / API test (no acoustic claim) |
| [web-flutter-real-acoustic-probe.json](web-flutter-real-acoustic-probe.json) | Physical run / derived metrics; see platform limitations |
| [web-flutter-rtc-fake-probe.json](web-flutter-rtc-fake-probe.json) | Fake-device transport / API test (no acoustic claim) |
| [web-flutter-rtc-real-probe.json](web-flutter-rtc-real-probe.json) | Physical run / derived metrics; see platform limitations |
| [web-rtc-acoustic-analysis.json](web-rtc-acoustic-analysis.json) | Physical run / derived metrics; see platform limitations |
| [web-worklet-smoke.json](web-worklet-smoke.json) | Fake-device transport / API test (no acoustic claim) |
| [windows-acoustic-wide-search.json](windows-acoustic-wide-search.json) | Physical run / derived metrics; see platform limitations |
| [windows-acoustic.json](windows-acoustic.json) | Physical run / derived metrics; see platform limitations |
| [windows-digital.json](windows-digital.json) | Digital fixture (no physical acoustic claim) |
| [windows-first-run-trace-error.json](windows-first-run-trace-error.json) | Failed startup/trace/lock trial; retained as failure |
| [windows-manual-playout-sdk.json](windows-manual-playout-sdk.json) | SDK provenance / recording isolation |
| [core-rebuild-parity.json](core-rebuild-parity.json) | Rebuilt native/Wasm digital parity after MSVC portability changes |
| [android-remote-far-gates.json](android-remote-far-gates.json) | Unlocked real-device decoded far speaker/AEC path and two clean/camera gates |
