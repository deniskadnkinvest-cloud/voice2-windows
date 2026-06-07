; Voice2 Windows Installer — Inno Setup 6
; Generated: 2026-05-20
; Builds Voice2-Setup-X.Y.Z.exe

#define AppName    "Voice2"
#define AppVersion "2.1.0"
#define AppPublisher "Voice2"
#define AppURL      "https://voice2.ru"
#define AppExeName  "Voice2.exe"

[Setup]
AppId               = {{A3F8B24E-71D2-4E8A-B3C5-29F1E7D8A501}
AppName             = {#AppName}
AppVersion          = {#AppVersion}
AppPublisher        = {#AppPublisher}
AppPublisherURL     = {#AppURL}
AppSupportURL       = {#AppURL}
DefaultDirName      = {localappdata}\{#AppName}
DefaultGroupName    = {#AppName}
DisableProgramGroupPage = yes
OutputDir           = ..\dist
OutputBaseFilename  = Voice2-Setup-{#AppVersion}
SetupIconFile       = ..\resources\mic.ico
Compression         = lzma2/ultra64
SolidCompression    = yes
WizardStyle         = modern
PrivilegesRequired  = lowest
; Registers voice2:// URL scheme for future magic-link login
ChangesAssociations = yes
UninstallDisplayIcon= {app}\{#AppExeName}
VersionInfoVersion  = {#AppVersion}
VersionInfoCompany  = Voice2
VersionInfoDescription= Voice2 — Голосовой ввод без облака

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Ярлык на рабочем столе"; GroupDescription: "Ярлыки:"; Flags: unchecked
Name: "startup";     Description: "Автозапуск при входе в систему"; GroupDescription: "Запуск:"; Flags: unchecked

[Files]
Source: "..\dist\Voice2\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#AppName}";                   Filename: "{app}\{#AppExeName}"
Name: "{group}\Удалить {#AppName}";           Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}";             Filename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}";             Filename: "{app}\{#AppExeName}"; Tasks: startup

[Registry]
; Register voice2:// URL scheme — used for future magic-link login
Root: HKCU; Subkey: "Software\Classes\voice2";                         ValueType: string; ValueName: ""; ValueData: "Voice2 App"
Root: HKCU; Subkey: "Software\Classes\voice2";                         ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\voice2\shell\open\command";      ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Запустить {#AppName}"; Flags: nowait postinstall skipifsilent
