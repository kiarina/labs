# PLATEAU SDK 3.2.2 on Unreal Engine 5.8.3 (macOS)

## Result

The unmodified official release fails module validation: `PLATEAURuntimeBPLibraries.Build.cs:70` selects `CppStandardVersion.Cpp17`, which UE 5.8 no longer supports. Editor launch and CityGML import were not reached.

A separate project copy changed ONLY this line to `CppStandardVersion.Default`. Compilation then found six diagnostics:

- `PLATEAUModelLandscape.cpp:99`: `ALandscape::bCanHaveLayersContent` no longer exists.
- `PLATEAUAttrInfoDrawGizmo.cpp:167,169,170`: `UWorld::ForegroundLineBatcher`, `PersistentLineBatcher`, and `LineBatcher` no longer exist.
- `RGraphEx.cpp:600`: misleading indentation promoted to error.
- `GeoGraph2d.h:333` lambda cannot be called by UE `ObjectPtr.h:1290` with its supplied type.

No further SDK fixes were attempted. This proves that this official release cannot be used unchanged in this tested Mac UE 5.8.3 environment. It does not establish migration effort, patched import success, Windows compatibility, or UE 5.5.4 behavior.

## Versions and evidence

- Test date: 2026-10-04. Hardware: Mac Studio M4 Max, 128 GB.
- UE 5.8.3, CL 58210709, compatible CL 55116800, branch ++UE5+Release-5.8.
- macOS 27.0.1 (26A434), arm64; Xcode 27.0 (27A266a).
- Apple clang 21.0.0; UBT toolchain label says Clang compiler 21.1.6.
- SDK tag v3.2.2, commit `9fa5b1463243f5ad94812fab7ea30a0eb12cd39a`.
- Official asset: `PLATEAU-SDK-for-Unreal-v3.2.2.0.zip`, 1,059,258,744 bytes.
- SHA256: `77885a88939df199ebba734765a206d5c5611ae7827aeaa0d9340452c150efee`.
- [Official release](https://github.com/Project-PLATEAU/PLATEAU-SDK-for-Unreal/releases/tag/v3.2.2) assumes UE 5.5.4.
- [Tag README](https://github.com/Project-PLATEAU/PLATEAU-SDK-for-Unreal/blob/v3.2.2/README.md) includes Mac ARM.
- [Installation manual](https://github.com/Project-PLATEAU/PLATEAU-SDK-for-Unreal/blob/v3.2.2/Documentation/manual/Installation.md): unpack release into project Plugins/PLATEAU-SDK-for-Unreal.
- Compared 382 release Source files with the tag: two CityGML headers differ only in CRLF versus LF.

## Reproduction

Minimal source project is in `project-source/`, without SDK binaries or generated files. Download the official ZIP and extract its plugin folder into `project-source/Plugins/`.

```sh
"$UE_ROOT/Engine/Build/BatchFiles/Mac/Build.sh" PlateauProbeEditor Mac Development -Project="$PWD/project-source/PlateauProbe.uproject" -architecture=arm64 -NoHotReload
```

Stages (logs in `logs/`; local paths redacted):

1. Initial project Target used V6 and failed shared Editor build settings. This is a probe configuration error, not an SDK failure.
2. Project Target corrected to UE 5.8 default V7: unmodified SDK rejected for C++17; exit 6, 2.46 seconds.
3. Separate copy with C++ default: UBA PCH creation failed around /tmp versus /private/tmp; exit 6, 17.44 seconds. This is an environment failure, not SDK API evidence.
4. Canonical /private/tmp project path with -NoUBA -NoUBALocal: passed PCH creation, reached the six source diagnostics above; exit 6, 75.05 seconds. Executor still labels itself UBA local but individual actions say [NoUba].
5. SDK-free control project, same minimal source and V7: **Succeeded**, exit 0, 18.83 seconds. This separates SDK compatibility errors from Xcode/UE project toolchain availability.

## Limits and next steps

No SDK-enabled Editor launch or import, rendering, packaging, or Windows tests. No engine or existing project configuration, global plugins, saves, or user experiment were edited. UBT wrote its normal per-user trace; it was not disabled or deleted.

A local already-downloaded PLATEAU Koto 2023 candidate exists: `udx/tran/53393622_tran_6697_op.gml`, 5,208 bytes. It was only identified by filename/size; usable geometry and SDK import have not been validated. No new city dataset was downloaded.

Further work would require an independent SDK fork fixing the language setting, Landscape API, LineBatcher API, lambda types, and indentation, followed by build, Editor launch, and minimal CityGML import. No publish, commit, or push was performed.
