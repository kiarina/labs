param(
 [Parameter(Mandatory=$true)][string]$NativeSource,
 [string]$OutDirectory='out-policy'
)
$ErrorActionPreference='Stop'
$lab=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$target=Join-Path $lab 'vendor/flutter_webrtc/third_party/libwebrtc'
if(Test-Path $target){throw 'Use a fresh lab-local SDK directory; existing work is preserved'}
$binary=Join-Path $NativeSource $OutDirectory
New-Item -ItemType Directory -Force (Join-Path $target 'lib')|Out-Null
Copy-Item -Recurse (Join-Path $NativeSource 'libwebrtc/include') $target
foreach($name in @('libwebrtc.dll','libwebrtc.dll.lib')){
 Copy-Item (Join-Path $binary $name) (Join-Path $target ('lib/'+$name))
}
$manifest=[ordered]@{
 kind='candidate SDK, not official'
 nativeCommit='51c367e209f8f12b39bd8dd0ca70bf588f42cb48'
 wrapperCommit='f7e9e5904ca743066bbd8cc0e5676b7a08c48436'
 corePatchSha256=(Get-FileHash (Join-Path $lab 'sdk/core-policy.patch')).Hash.ToLower()
 factoryPatchSha256=(Get-FileHash (Join-Path $lab 'sdk/factory-policy.patch')).Hash.ToLower()
 dllSha256=(Get-FileHash (Join-Path $target 'lib/libwebrtc.dll')).Hash.ToLower()
 importLibrarySha256=(Get-FileHash (Join-Path $target 'lib/libwebrtc.dll.lib')).Hash.ToLower()
}
New-Item -ItemType Directory -Force (Join-Path $lab 'build')|Out-Null
$manifest|ConvertTo-Json|Set-Content -Encoding ASCII (Join-Path $lab 'build/sdk-manifest.json')
