; ==========================================================
; Shirabox 安装包构建脚本 (已修正 x64 路径)
; ==========================================================

; 1. Project root (the directory containing this script)
#define ProjectDir SourcePath

; 2. 【定义源文件目录】(修正: 加上了 \x64)
#define ReleaseDir ProjectDir + "\build\windows\x64\runner\Release"

; 3. 基本信息
#define MyAppName "Shirabox"
#define MyAppVersion "0.9.0"
#define MyAppPublisher "Shirakara"
#define MyAppExeName "shirabox.exe"

[Setup]
; AppId 唯一标识符
AppId={{E6805721-692B-4521-995C-6725890832F6}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}

; 默认安装到用户目录 (无需管理员权限)
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest

; 输出设置
OutputDir={#ProjectDir}\dist
OutputBaseFilename=Shirabox_Setup_v{#MyAppVersion}

; 图标 (直接引用源码里的 ico)
SetupIconFile={#ProjectDir}\windows\runner\resources\app_icon.ico

; 压缩设置
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; ==========================================================
; 抓取 Release 文件夹下的所有内容
; ==========================================================

; 1. 主程序
Source: "{#ReleaseDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; 2. 所有依赖 (DLL, data文件夹, scrcpy等)
; 递归抓取所有子文件夹
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
