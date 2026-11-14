; Inno Setup script for the CloudBox PC agent.
;
; Produces dist\cloudbox-setup-<version>.exe. Prefer the wrapper, which cross-compiles the
; agent and injects the version:
;
;     pwsh eng/build-installer.ps1
;
; or directly:
;
;     ISCC.exe /DVersion=0.01.13.11.26 cloudbox.iss
;
; The installer deliberately ships only the agent. The Flutter toolchain is a build-time
; dependency for the Android app, not something the PC needs at runtime.

#ifndef Version
  #define Version "0.0.0"
#endif

#ifndef SourceExe
  #define SourceExe "..\agent\dist\cloudbox.exe"
#endif

#define AppName "CloudBox"
#define AppExeName "cloudbox.exe"
#define FirewallRule "CloudBox agent"

[Setup]
AppId={{8E2F0A1C-5B7D-4C3E-9A21-7F4D6B0C1E55}
AppName={#AppName}
AppVersion={#Version}
AppVerName={#AppName} {#Version}
AppPublisher=CloudBox
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName} {#Version}
OutputDir=..\dist
OutputBaseFilename=cloudbox-setup-{#Version}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Install per-user by default so no administrator is required; the user can still choose an
; all-users install, which is what unlocks the firewall rule below.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Start CloudBox automatically when I sign in"; GroupDescription: "Startup:"; Flags: checkedonce
Name: "firewall"; Description: "Allow phones on my network to reach this PC (Windows Firewall, TCP 8443)"; GroupDescription: "Network:"; Flags: checkedonce; Check: IsAdminInstallMode

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "{#AppExeName}"; Flags: ignoreversion
Source: "cloudbox-autostart.vbs"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\CloudBox"; Filename: "{app}\{#AppExeName}"; Parameters: "serve"; WorkingDir: "{app}"; Comment: "Start the agent and show a pairing code"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Registry]
; Per-user autostart. HKCU is correct even for an all-users install: the agent runs as the
; signed-in user and writes to that user's data directory.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{sys}\wscript.exe"" ""{app}\cloudbox-autostart.vbs"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#FirewallRule}"" dir=in action=allow protocol=TCP localport=8443 profile=private,domain"; Flags: runhidden; Tasks: firewall; StatusMsg: "Adding Windows Firewall rule..."
Filename: "{app}\{#AppExeName}"; Parameters: "serve"; Description: "Start CloudBox now and show a pairing code"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
; The agent's identity, cache and sync folder live in the user's data directory and are
; deliberately left behind, so reinstalling keeps devices paired.
Type: files; Name: "{app}\cloudbox-autostart.vbs"
