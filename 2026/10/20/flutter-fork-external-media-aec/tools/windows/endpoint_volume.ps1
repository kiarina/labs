# Read-only endpoint volume/mute; opens no capture or render stream.
if (-not ('VolumeRead' -as [type])) { Add-Type -Path "$PSScriptRoot/endpoint_volume.cs" }
[VolumeRead]::Get(1)
[VolumeRead]::Get(0)
