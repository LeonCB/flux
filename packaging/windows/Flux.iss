#ifndef AppVersion
  #error AppVersion is required
#endif
[Setup]
AppId={{AE5327E7-474B-47B6-BF01-2D5352A418AF}
AppName=Flux
AppVersion={#AppVersion}
AppPublisher=Kenan Kasumović
AppPublisherURL=https://luma.ksmvc.ch
AppSupportURL=https://github.com/LeonCB/flux/issues
AppUpdatesURL=https://github.com/LeonCB/flux/releases
DefaultDirName={localappdata}\Flux\Screensaver
DisableDirPage=yes
UsePreviousAppDir=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=no
RestartApplications=no
LicenseFile=..\..\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=Flux-{#AppVersion}-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Flux.ico
VersionInfoVersion={#AppVersion}.0

[Files]
Source: "Flux.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\Flux.scr"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\deployment.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\Uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\Uninstall.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "setup-actions.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "setup-actions.ps1"; Flags: dontcopy
Source: "deployment.ps1"; Flags: dontcopy

[Registry]
Root: HKCU; Subkey: "Control Panel\Desktop"; ValueType: string; ValueName: "SCRNSAVE.EXE"; ValueData: "{app}\Flux.scr"

[Run]
Filename: "{sys}\rundll32.exe"; Parameters: "shell32.dll,Control_RunDLL desk.cpl,,1"; Description: "Open Windows Screen Saver Settings"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\installation.json"
Type: files; Name: "{app}\Flux.log"

[Code]
function RunAction(ScriptPath, Action: String): Boolean;
var ExitCode: Integer;
begin
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath +
    '" -Action ' + Action + ' -InstallDirectory "' + ExpandConstant('{app}') + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  if Result then Result := ExitCode = 0;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  ExtractTemporaryFile('setup-actions.ps1');
  ExtractTemporaryFile('deployment.ps1');
  if not RunAction(ExpandConstant('{tmp}\setup-actions.ps1'), 'Prepare') then
    Result := 'Close Flux and Windows Screen Saver Settings, then retry. Installation metadata must be valid.'
  else Result := '';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    if not RunAction(ExpandConstant('{app}\setup-actions.ps1'), 'Restore') then
      RaiseException('Close Flux and Windows Screen Saver Settings, then retry. Uninstall could not restore the previous selection.');
end;
