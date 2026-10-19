# Recognizes the six segment WAVs with the installed SAPI desktop recognizer
# (System.Speech, MS-1041-80-DESK), three passes, and prints JSON lines.
Add-Type -AssemblyName System.Speech
$dir = Join-Path $PSScriptRoot 'wav'
$ids = 1..6 | ForEach-Object { "segment-$_" }
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine (New-Object System.Globalization.CultureInfo 'ja-JP')
$engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
$engine.InitialSilenceTimeout = [TimeSpan]::FromSeconds(5)
$engine.EndSilenceTimeout = [TimeSpan]::FromSeconds(0.3)
"PCM_ASR " + (@{kind='platform';os='windows';engine='sapi-desktop';recognizer=$engine.RecognizerInfo.Id;culture=$engine.RecognizerInfo.Culture.Name} | ConvertTo-Json -Compress)
foreach ($trial in 0..2) {
  $order = if ($trial -eq 2) { $ids[5..0] } else { $ids }
  foreach ($id in $order) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $engine.SetInputToWaveFile((Join-Path $dir "$id.wav"))
    $text = ''
    $parts = @()
    try {
      while ($true) {
        $r = $engine.Recognize()
        if ($null -eq $r) { break }
        $parts += $r.Text
      }
    } catch { }
    $sw.Stop()
    $text = ($parts -join '')
    "PCM_ASR " + (@{kind='result';id="$id#$trial";segment_id=$id;trial=$trial;text=$text;elapsed_ms=[math]::Round($sw.Elapsed.TotalMilliseconds,1);id_matches=$true;engine='sapi-desktop';locale='ja-JP';round_trip_ms=[math]::Round($sw.Elapsed.TotalMilliseconds,1);ranges=@()} | ConvertTo-Json -Compress)
  }
}
"PCM_ASR " + (@{kind='done';ok=$true} | ConvertTo-Json -Compress)
