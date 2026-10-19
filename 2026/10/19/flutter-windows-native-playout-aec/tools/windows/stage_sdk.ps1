param(
 [Parameter(Mandatory=$true)][string]$NativeSource,
 [string]$OutDirectory='out-policy',
 [string]$ExpectedSha256='73b672f90beba282e04ae6dd9dbcb7b3af574d192977ae9224c382075dbcd740'
)
$ErrorActionPreference='Stop'
$lab=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$target=Join-Path $lab 'vendor/flutter_webrtc/third_party/libwebrtc'
if(Test-Path $target){throw 'Use a fresh lab-local SDK directory; existing work is preserved'}
$binary=Join-Path $NativeSource $OutDirectory
if((Get-FileHash (Join-Path $binary 'libwebrtc.dll')).Hash.ToLower() -ne $ExpectedSha256){throw 'DLL differs from expected candidate; no files staged'}
New-Item -ItemType Directory -Force (Join-Path $target 'lib')|Out-Null
Copy-Item -Recurse (Join-Path $NativeSource 'libwebrtc/include') $target
foreach($name in @('libwebrtc.dll','libwebrtc.dll.lib')){
 Copy-Item (Join-Path $binary $name) (Join-Path $target ('lib/'+$name))
}
$manifest=[ordered]@{
 kind='candidate SDK, not official'
 nativeCommit='51c367e209f8f12b39bd8dd0ca70bf588f42cb48'
 wrapperCommit='f9a23f98e19c2784fd293941b9e67a43977f1635'
 coreCommit='543b9cb70ee7b07311d4f4ddefc014278d6066d4'
 dllSha256=(Get-FileHash (Join-Path $target 'lib/libwebrtc.dll')).Hash.ToLower()
 importLibrarySha256=(Get-FileHash (Join-Path $target 'lib/libwebrtc.dll.lib')).Hash.ToLower()
}
New-Item -ItemType Directory -Force (Join-Path $lab 'build')|Out-Null
$manifest|ConvertTo-Json|Set-Content -Encoding ASCII (Join-Path $lab 'build/sdk-manifest.json')
