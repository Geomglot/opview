; GeoRivView Replay's Windows installer (Inno Setup 6), made by build_windows.ps1, which passes:
;   /DAppVersion=0.1.2-test.1   the full version, also in the file name
;   /DNumericVersion=0.1.2.7    four numbers for Windows' file properties (the test number cannot go there)
;   /DSourceDir=...             the finished program folder (dist\GeoRivView Replay)
; It installs for the current user only, so it needs no administrator. Installing a newer version over an older one
; replaces it in place; the app's updater runs it with /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH.
; Settings (%APPDATA%\OPRivViewReplay) and stored drives (%LOCALAPPDATA%\OPRivViewReplay) are not in the install folder,
; so updates keep them; uninstalling offers to delete them.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef NumericVersion
  #define NumericVersion "0.0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\GeoRivView Replay"
#endif

[Setup]
; the same AppId for every version, so a new version replaces the old one; never change it
AppId={{8C0E72F8-57AB-4BA2-A8A9-C9919B9A221C}
AppName=GeoRivView Replay
AppVersion={#AppVersion}
AppVerName=GeoRivView Replay {#AppVersion}
VersionInfoVersion={#NumericVersion}
AppPublisher=Geomglot
AppPublisherURL=https://github.com/Geomglot/opview
AppSupportURL=https://github.com/Geomglot/opview/issues
AppUpdatesURL=https://github.com/Geomglot/opview/releases
DefaultDirName={localappdata}\Programs\GeoRivView Replay
DisableDirPage=auto
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=GeoRivView-Replay-{#AppVersion}-Windows
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=GeoRivView Replay
UninstallDisplayIcon={app}\OPRivViewReplay.exe
; a running copy (the app or its server) is closed before its files are replaced
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

; parts whose files change from version to version are cleared first, so nothing from an older version is left among them
[InstallDelete]
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\oprivview-replay-server"
Type: filesandordirs; Name: "{app}\ffmpeg"
Type: filesandordirs; Name: "{app}\licenses"
; the shortcuts from before the app was renamed GeoRivView; new ones are made under the new name
Type: files; Name: "{autoprograms}\OPRivView Replay.lnk"
Type: files; Name: "{autodesktop}\OPRivView Replay.lnk"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\GeoRivView Replay"; Filename: "{app}\OPRivViewReplay.exe"
Name: "{autodesktop}\GeoRivView Replay"; Filename: "{app}\OPRivViewReplay.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\OPRivViewReplay.exe"; Description: "{cm:LaunchProgram,GeoRivView Replay}"; Flags: nowait postinstall skipifsilent
; after an update from inside the app, which runs this installer silently, open the app again
Filename: "{app}\OPRivViewReplay.exe"; Flags: nowait; Check: Relaunch

[Code]
function Relaunch: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to ParamCount do
    if CompareText(ParamStr(i), '/RELAUNCH') = 0 then Result := WizardSilent;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and not UninstallSilent then
    if MsgBox('Also delete GeoRivView Replay''s settings and the drives it stored?' + #13#10 + #13#10 +
              'Clips you saved are not touched either way.', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    begin
      DelTree(ExpandConstant('{userappdata}\OPRivViewReplay'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\OPRivViewReplay'), True, True, True);
    end;
end;
