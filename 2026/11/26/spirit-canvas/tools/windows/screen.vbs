' Saves the desktop to logs\screen.png without a console window over it
' (run from an interactive scheduled task: /tr <this file>).
Dim here: here = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\screen.ps1""", 0, True
