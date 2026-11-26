# Saves what is on the desktop (the real screen, not the app's own capture)
# to logs\screen.png. Run from an interactive scheduled task (screen.vbs).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$root = Join-Path $PSScriptRoot '..\..'
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$bmp.Save((Join-Path $root 'logs\screen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
