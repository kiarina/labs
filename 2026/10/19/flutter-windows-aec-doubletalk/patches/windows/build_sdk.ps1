# Dedicated, reproducible Windows native SDK build; never edits pub cache.
param([Parameter(Mandatory=$true)][string]$BuildRoot, [switch]$SkipSync)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptStart = Get-Date
$BuildRoot = [System.IO.Path]::GetFullPath($BuildRoot)
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:DEPOT_TOOLS_UPDATE = '0'
$env:GYP_MSVS_VERSION = '2022'
$env:GYP_MSVS_OVERRIDE_PATH = 'C:\Program Files\Microsoft Visual Studio\2022\Community'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.longpaths'
$env:GIT_CONFIG_VALUE_0 = 'true'
function Invoke-Checked([string]$Program, [string[]]$Parameters) {
    Write-Output ((Get-Date -Format o) + ' ' + $Program + ' ' + ($Parameters -join ' '))
    & $Program @Parameters
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
New-Item -ItemType Directory -Force $BuildRoot | Out-Null
Set-Location $BuildRoot
if (-not (Test-Path 'depot_tools')) {
    Invoke-Checked git @('clone','--depth','1','https://chromium.googlesource.com/chromium/tools/depot_tools.git','depot_tools')
}
Invoke-Checked git @('-C','depot_tools','fetch','--depth','1','origin','d38909eb68d85b91259f4bf20fe5ebcd38461bc2')
Invoke-Checked git @('-C','depot_tools','checkout','--detach','d38909eb68d85b91259f4bf20fe5ebcd38461bc2')
$env:PATH = "$BuildRoot\depot_tools;" + $env:PATH
if (-not (Test-Path 'src')) {
    Invoke-Checked git @('clone','--depth','1','--branch','m150_release','https://github.com/webrtc-sdk/webrtc.git','src')
}
Invoke-Checked git @('-C','src','fetch','--depth','1','origin','51c367e209f8f12b39bd8dd0ca70bf588f42cb48')
Invoke-Checked git @('-C','src','checkout','--detach','51c367e209f8f12b39bd8dd0ca70bf588f42cb48')
@'
solutions = [{
  "name": "src",
  "url": "https://github.com/webrtc-sdk/webrtc.git@51c367e209f8f12b39bd8dd0ca70bf588f42cb48",
  "deps_file": "DEPS", "managed": False,
  "custom_deps": {}, "custom_vars": {},
}]
target_os = ["win"]
'@ | Set-Content -Encoding ASCII '.gclient'
# Library-only experiment: do not download upstream audio/video test fixtures.
$depsPath = Join-Path $BuildRoot 'src/DEPS'
$deps = [System.IO.File]::ReadAllText($depsPath)
$resourceAnchor = "    # Download test resources, i.e. video and audio files from Google Storage."
$resourceReplacement = $resourceAnchor + "`n    'condition': 'False',  # external capture lab: no fixture downloads"
if (-not $deps.Contains($resourceReplacement)) {
    if (-not $deps.Contains($resourceAnchor)) { throw 'Missing pinned test-resource hook anchor' }
    $deps = $deps.Replace($resourceAnchor, $resourceReplacement)
    [System.IO.File]::WriteAllText($depsPath, $deps, (New-Object System.Text.UTF8Encoding($false)))
}
if (-not $SkipSync) {
    Invoke-Checked "$BuildRoot\depot_tools\gclient.bat" @('sync','--no-history','--shallow','--jobs=8')
}
# Fork commits can lack Chromium Change-Id trailers. The generic LASTCHANGE
# hook then writes epoch 0, which yields a negative PE linker timestamp.
$buildCommitEpoch = (& git -C 'src/build' show -s '--format=%ct' HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $buildCommitEpoch -notmatch '^[0-9]+$') { throw 'Cannot resolve pinned build-support commit time' }
$buildCommitEpoch | Set-Content -Encoding ASCII 'src/build/util/LASTCHANGE.committime'
Write-Output "Pinned build-support commit epoch: $buildCommitEpoch"
if (-not (Test-Path 'wrapper')) {
    Invoke-Checked git @('clone','--depth','1','--branch','libwebrtc.m150.7871.03','https://github.com/webrtc-sdk/libwebrtc.git','wrapper')
}
Invoke-Checked git @('-C','wrapper','fetch','--depth','1','origin','070aa6d763c16027ba53c0965107658c837a4dae')
Invoke-Checked git @('-C','wrapper','checkout','--detach','070aa6d763c16027ba53c0965107658c837a4dae')
Invoke-Checked git @('-C','wrapper','rev-parse','HEAD')
New-Item -ItemType Directory -Force 'src/libwebrtc' | Out-Null
foreach ($name in @('include','src','patches','test','BUILD.gn','LICENSE')) {
    Copy-Item -Recurse -Force "wrapper/$name" 'src/libwebrtc/'
}
Push-Location src
$patches = @('custom_audio_source_m150.patch','add_libwebrtc_build_target.patch','allow_176k4_192k_shared_mode_formats.patch')
$patchStamp = Join-Path $BuildRoot 'upstream-patches-applied.txt'
$patchHashes = @($patches | ForEach-Object { (Get-FileHash -Algorithm SHA256 "libwebrtc/patches/$_").Hash })
$patchIdentity = (@('51c367e209f8f12b39bd8dd0ca70bf588f42cb48') + $patchHashes) -join ':'
if (Test-Path $patchStamp) {
    if ((Get-Content $patchStamp -Raw).Trim() -ne $patchIdentity) { throw 'Upstream patch stamp mismatch; use a fresh dedicated BuildRoot' }
    Write-Output 'Pinned upstream patches already applied; preserving the subsequent isolation instrumentation'
} else {
foreach ($patch in $patches) {
    & git apply --check "libwebrtc/patches/$patch" --ignore-space-change --ignore-whitespace
    if ($LASTEXITCODE -eq 0) {
        Invoke-Checked git @('apply',"libwebrtc/patches/$patch",'--ignore-space-change','--ignore-whitespace','--whitespace=nowarn')
    } else {
        & git apply --reverse --check "libwebrtc/patches/$patch" --ignore-space-change --ignore-whitespace
        if ($LASTEXITCODE -ne 0) { throw "Upstream patch neither clean nor already applied: $patch" }
        Write-Output "Already applied upstream patch: $patch"
    }
}
    $patchIdentity | Set-Content -Encoding ASCII $patchStamp
}
Invoke-Checked python @("$PSScriptRoot/apply_sdk.py",'.')
$env:PATH = "$BuildRoot\depot_tools\.cipd_bin\3.11\bin;" + $env:PATH
# Write args.gn directly: Windows PowerShell strips embedded native-argument quotes.
New-Item -ItemType Directory -Force 'out-isolated' | Out-Null
@'
use_siso=false
use_remoteexec=false
is_debug=false
is_clang=true
target_cpu="x64"
use_custom_libcxx=false
rtc_libvpx_build_vp9=true
enable_libaom=true
# The wrapper declares a test target; only libwebrtc is compiled below.
rtc_include_tests=true
rtc_build_examples=false
rtc_build_tools=false
is_component_build=false
rtc_enable_protobuf=false
rtc_use_h264=true
ffmpeg_branding="Chrome"
rtc_use_h265=true
symbol_level=0
enable_iterator_debugging=false
'@ | Set-Content -Encoding ASCII 'out-isolated/args.gn'
Invoke-Checked "$BuildRoot\src\buildtools\win\gn.exe" @('gen','out-isolated')
$compileStart = Get-Date
Invoke-Checked "$BuildRoot\src\third_party\ninja\ninja.exe" @('-C','out-isolated','-j','12','libwebrtc')
Pop-Location
$complete = Get-Date
$manifest = [ordered]@{
    nativeSource = '51c367e209f8f12b39bd8dd0ca70bf588f42cb48'
    wrapperSource = '070aa6d763c16027ba53c0965107658c837a4dae'
    depotTools = 'd38909eb68d85b91259f4bf20fe5ebcd38461bc2'
    buildSupportCommitEpoch = [int64]$buildCommitEpoch
    patchSha256 = (Get-FileHash -Algorithm SHA256 "$PSScriptRoot/apply_sdk.py").Hash.ToLower()
    sdkSha256 = (Get-FileHash -Algorithm SHA256 "$BuildRoot/src/out-isolated/libwebrtc.dll").Hash.ToLower()
    sdkBytes = (Get-Item "$BuildRoot/src/out-isolated/libwebrtc.dll").Length
    invocationStarted = $scriptStart.ToString('o')
    completed = $complete.ToString('o')
    invocationSeconds = ($complete - $scriptStart).TotalSeconds
    compileSeconds = ($complete - $compileStart).TotalSeconds
    upstreamTestResourceHookDisabled = $true
}
$manifest | ConvertTo-Json | Set-Content -Encoding ASCII (Join-Path $BuildRoot 'sdk-manifest.json')
Write-Output ($complete.ToString('o') + ' BUILD_COMPLETE')
