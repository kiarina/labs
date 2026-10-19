# Lists the OS build, installed SAPI recognizers and Speech language capabilities.
[System.Environment]::OSVersion.VersionString
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
Add-Type -AssemblyName System.Speech
'--- SAPI recognizers (System.Speech) ---'
[System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | ForEach-Object { $_.Id + ' | ' + $_.Culture.Name + ' | ' + $_.Name }
'--- Speech capabilities ---'
Get-WindowsCapability -Online | Where-Object Name -like 'Language.Speech*' | ForEach-Object { $_.Name + ' | ' + $_.State }
'--- Online speech recognition privacy toggle (HasAccepted) ---'
(Get-ItemProperty 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -ErrorAction SilentlyContinue).HasAccepted
'--- OneCore recognizers (registry) ---'
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Recognizers\Tokens' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName + ' | ' + (Get-ItemProperty $_.PSPath).'(default)' }
'--- Foundry Local / winget ---'
(Get-Command foundry -ErrorAction SilentlyContinue).Source
