; U-Panel Windows installer (Inno Setup 6).
; Build on Windows after: flutter build windows --release
;
; Compile:
;   ISCC.exe installer\U-Panel.iss /DMyAppVersion=1.0.0
; Or:
;   powershell -File scripts\build-windows-installer.ps1

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppName "U-Panel"
#define MyAppPublisher "Orion13 Technologies"
#define MyAppURL "https://kiu.orion13.us"
#define MyAppExeName "u_panel.exe"
#define BuildRoot "..\build\windows\x64\runner\Release"
#define SetupIcon "..\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{B7E12B46-EFE2-406A-8C47-05DAD6FFF724}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=output
OutputBaseFilename=U-Panel-{#MyAppVersion}-windows-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
DisableProgramGroupPage=yes
SetupIconFile={#SetupIcon}
UninstallDisplayIcon={app}\{#MyAppExeName}
#ifexist "{#BuildRoot}\{#MyAppExeName}"
VersionInfoVersion={#MyAppVersion}.0
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "{#BuildRoot}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
  if not FileExists(ExpandConstant('{#BuildRoot}\{#MyAppExeName}')) then
  begin
    MsgBox(
      'Release build not found.' + #13#10 +
      'Run: flutter build windows --release' + #13#10 +
      'Expected: {#BuildRoot}\{#MyAppExeName}',
      mbError, MB_OK);
    Result := False;
  end
  else
    Result := True;
end;
