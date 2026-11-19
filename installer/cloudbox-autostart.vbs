' CloudBox — start the PC agent at sign-in without leaving a console window open.
'
' Installed next to cloudbox.exe by cloudbox-setup-*.exe. The Windows "Run" entry points here,
' which finds the agent beside this script and launches `cloudbox serve` hidden. The PC app uses
' this same launcher when it needs to start the agent itself. To watch the agent, open the Agent
' tab in "CloudBox", or start "CloudBox Agent" for the raw console.
Option Explicit

Dim fso, shell, here, exe
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
exe = here & "\cloudbox.exe"

If Not fso.FileExists(exe) Then
    ' The agent is gone (uninstalled or moved); nothing to do.
    WScript.Quit 1
End If

shell.CurrentDirectory = here
' 0 = hidden window, False = do not wait for the process to exit.
shell.Run """" & exe & """ serve", 0, False
