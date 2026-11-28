; AntiRKN per-user installer (Inno Setup 6). Built by .github/workflows/build.yml:
;   ISCC.exe /DAppVersion=X.Y.Z /DBuildNumber=N /DSourceDir=<bundle> /DOutputDir=<dist> packaging\windows\antirkn.iss
; Silent update from the app (closes the running app, relaunches it afterwards):
;   AntiRKN-vX.Y.Z-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /relaunch=1
; User data (%APPDATA%, %LOCALAPPDATA% outside {app}) is never removed by the uninstaller.

#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildNumber
  #error BuildNumber is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

#define AppName "AntiRKN"
#define AppExe "antirkn_manager.exe"

[Setup]
; Stable AppId: never change it, otherwise upgrades install side by side.
AppId={{F122C408-92CD-4DEA-895B-655A4CDABC33}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=AntiRKN
AppPublisherURL=https://github.com/CyberCat2033/AntiRKN
AppSupportURL=https://github.com/CyberCat2033/AntiRKN/issues
AppUpdatesURL=https://github.com/CyberCat2033/AntiRKN/releases
VersionInfoVersion={#AppVersion}.0
VersionInfoProductVersion={#AppVersion}
; Per-user install without UAC: {autopf} resolves to %LOCALAPPDATA%\Programs.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
UsePreviousAppDir=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; The app holds this mutex while running (see docs/release-ci.md); together with
; the Restart Manager it prevents replacing files of a running instance.
AppMutex=Local\AntiRKNManagerRunning,Global\AntiRKNManagerRunning
CloseApplications=yes
RestartApplications=no
SetupIconFile=..\..\apps\manager\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename=AntiRKN-v{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; GPL text on the license page; /VERYSILENT updates skip it.
LicenseFile=..\..\LICENSE
ShowLanguageDialog=auto

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Tells the app it was installed by this installer (update = run the next setup).
Source: "install-kind"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\DISCLAIMER.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: RelaunchRequested

; No [UninstallDelete] for user data on purpose: the encrypted workspace,
; tokens and settings outside {app} survive uninstall and reinstall.

[Code]
function RelaunchRequested: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:relaunch|0}') = '1');
end;
