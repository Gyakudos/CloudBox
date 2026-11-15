; Inno Setup script for the CloudBox PC agent.
;
; Produces dist\cloudbox-setup-<version>.exe. Prefer the wrapper, which cross-compiles the
; agent and injects the version:
;
;     pwsh eng/build-installer.ps1
;
; or directly:
;
;     ISCC.exe /DVersion=0.01.15.11.26 cloudbox.iss
;
; The installer ships the agent, and can optionally set up the Flutter SDK on the PC (the
; "flutter" task) so the Android app can be built there. The Flutter toolchain is never a runtime
; dependency of the agent, so it is fetched on demand rather than bundled: the official Windows
; archive is ~1.9 GB, far larger than the agent itself.

#ifndef Version
  #define Version "0.0.0"
#endif

#ifndef SourceExe
  #define SourceExe "..\agent\dist\cloudbox.exe"
#endif

#define AppName "CloudBox"
#define AppExeName "cloudbox.exe"
#define FirewallRule "CloudBox agent"

; Flutter SDK, installed by the optional "flutter" task. Pinned to the version CI builds the
; Android app with (see .github/workflows/ci.yml), so a PC-built APK matches the released one.
; The archive contains a single top-level "flutter" directory.
#define FlutterVersion "3.47.8"
#define FlutterZip "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_" + FlutterVersion + "-stable.zip"

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
Name: "flutter"; Description: "Also install the Flutter SDK {#FlutterVersion} (~1.9 GB download) to build the Android app on this PC"; GroupDescription: "Developer tools:"; Flags: checkedonce

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "{#AppExeName}"; Flags: ignoreversion
Source: "cloudbox-autostart.vbs"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
; Parent directory for the Flutter SDK the "flutter" task downloads and extracts.
Name: "{localappdata}\CloudBox"; Tasks: flutter

[Icons]
Name: "{group}\CloudBox"; Filename: "{app}\{#AppExeName}"; Parameters: "serve"; WorkingDir: "{app}"; Comment: "Start the agent and show a pairing code"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Registry]
; Per-user autostart. HKCU is correct even for an all-users install: the agent runs as the
; signed-in user and writes to that user's data directory.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{sys}\wscript.exe"" ""{app}\cloudbox-autostart.vbs"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
; The Flutter SDK: fetch the pinned archive with curl (streams to disk and resumes a partial file
; on retry), extract it with tar (bsdtar, present on Windows 10 1803+), then drop the archive.
; Both steps ignore failures and are verified in [Code] below, so a flaky download cannot fail the
; whole install — the agent works perfectly well without Flutter.
Filename: "{cmd}"; Parameters: "/c {sys}\curl.exe --fail --location --retry 5 --retry-delay 3 --retry-all-errors --continue-at - --output ""{localappdata}\CloudBox\flutter-{#FlutterVersion}.zip"" ""{#FlutterZip}"" & exit /b 0"; StatusMsg: "Downloading the Flutter SDK {#FlutterVersion} (~1.9 GB)..."; Flags: runhidden waituntilterminated; Tasks: flutter
Filename: "{cmd}"; Parameters: "/c {sys}\tar.exe -xf ""{localappdata}\CloudBox\flutter-{#FlutterVersion}.zip"" -C ""{localappdata}\CloudBox"" & exit /b 0"; StatusMsg: "Extracting the Flutter SDK..."; Flags: runhidden waituntilterminated; Tasks: flutter
Filename: "{cmd}"; Parameters: "/c del /q ""{localappdata}\CloudBox\flutter-{#FlutterVersion}.zip"" & exit /b 0"; Flags: runhidden waituntilterminated; Tasks: flutter
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#FirewallRule}"" dir=in action=allow protocol=TCP localport=8443 profile=private,domain"; Flags: runhidden; Tasks: firewall; StatusMsg: "Adding Windows Firewall rule..."
Filename: "{app}\{#AppExeName}"; Parameters: "serve"; Description: "Start CloudBox now and show a pairing code"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
; The agent's identity, cache and sync folder live in the user's data directory and are
; deliberately left behind, so reinstalling keeps devices paired.
Type: files; Name: "{app}\cloudbox-autostart.vbs"
; The Flutter SDK, if the optional task installed it. Nothing else lives here.
Type: filesandordirs; Name: "{localappdata}\CloudBox\flutter"

[Code]
const
  EnvKey = 'Environment';

var
  // Set at ssPostInstall; read at ssDone, after the [Run] entries have fetched the SDK.
  FlutterTaskSelected: Boolean;

function FlutterRoot: string;
begin
  Result := ExpandConstant('{localappdata}\CloudBox\flutter');
end;

function FlutterBin: string;
begin
  Result := FlutterRoot + '\bin';
end;

function PathHasEntry(const PathValue, Entry: string): Boolean;
begin
  Result := Pos(';' + Uppercase(Entry) + ';', ';' + Uppercase(PathValue) + ';') > 0;
end;

// Add <flutter>\bin to the *user* PATH, preserving whatever is already there. The value is
// written back as REG_EXPAND_SZ so any %VARIABLES% in the existing PATH keep working.
procedure AddFlutterToPath;
var
  OldPath: string;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, EnvKey, 'Path', OldPath) then
    OldPath := '';
  if PathHasEntry(OldPath, FlutterBin) then
    Exit;
  if (OldPath <> '') and (OldPath[Length(OldPath)] <> ';') then
    OldPath := OldPath + ';';
  RegWriteExpandStringValue(HKEY_CURRENT_USER, EnvKey, 'Path', OldPath + FlutterBin);
end;

// Remove our entry on uninstall, matching case-insensitively and leaving the rest intact.
procedure RemoveFlutterFromPath;
var
  OldPath, NewPath, Segment: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, EnvKey, 'Path', OldPath) then
    Exit;
  NewPath := '';
  while OldPath <> '' do
  begin
    P := Pos(';', OldPath);
    if P = 0 then
    begin
      Segment := OldPath;
      OldPath := '';
    end
    else
    begin
      Segment := Copy(OldPath, 1, P - 1);
      OldPath := Copy(OldPath, P + 1, Length(OldPath));
    end;
    if (Segment <> '') and (not SameText(Segment, FlutterBin)) then
    begin
      if NewPath <> '' then
        NewPath := NewPath + ';';
      NewPath := NewPath + Segment;
    end;
  end;
  RegWriteExpandStringValue(HKEY_CURRENT_USER, EnvKey, 'Path', NewPath);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    // Remember the choice now. The [Run] entries that fetch and extract the SDK execute after
    // this event, so we only touch PATH once they have finished, at ssDone.
    FlutterTaskSelected := WizardIsTaskSelected('flutter')
  else if CurStep = ssDone then
  begin
    if FlutterTaskSelected then
    begin
      if FileExists(FlutterRoot + '\bin\flutter.bat') then
        AddFlutterToPath
      else if not WizardSilent then
        MsgBox('The Flutter SDK could not be installed. You can install it later from'
          + #13#10 + 'https://docs.flutter.dev/get-started/install/windows, or re-run this'
          + #13#10 + 'installer and keep the "Flutter SDK" task selected.',
          mbInformation, MB_OK);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveFlutterFromPath;
end;
