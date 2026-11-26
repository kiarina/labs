# Minimizes or restores the app's window, or reports it (run in the desktop
# session: an interactive scheduled task). Writes what it found to
# %ROOT%\logs\window.log. Usage: window.ps1 minimize|restore|status
param([string]$Action = 'status')
$root = Join-Path $PSScriptRoot '..\..'
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
$p = Get-Process spirit_canvas -ErrorAction SilentlyContinue | Select-Object -First 1
$found = [IntPtr]::Zero
if ($p) {
  [W]::EnumWindows({ param($h, $l)
    $id = 0; [void][W]::GetWindowThreadProcessId($h, [ref]$id)
    $sb = New-Object System.Text.StringBuilder 256; [void][W]::GetClassName($h, $sb, 256)
    if ($id -eq $p.Id -and $sb.ToString() -eq 'FLUTTER_RUNNER_WIN32_WINDOW') { $script:found = $h; return $false }
    return $true }, [IntPtr]::Zero) | Out-Null
}
if ($found -ne [IntPtr]::Zero) {
  if ($Action -eq 'minimize') { [void][W]::ShowWindow($found, 6) }
  if ($Action -eq 'restore') { [void][W]::ShowWindow($found, 9) }
  Start-Sleep -Milliseconds 500
  $fg = [W]::GetForegroundWindow()
  "action=$Action iconic=$([W]::IsIconic($found)) foreground=$($fg -eq $found)" | Out-File -Append -Encoding utf8 (Join-Path $root 'logs\window.log')
} else {
  "action=$Action no window" | Out-File -Append -Encoding utf8 (Join-Path $root 'logs\window.log')
}
