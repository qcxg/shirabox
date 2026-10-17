# Development and packaging

All commands run from the directory containing `pubspec.yaml`. The repository
root is the Flutter project; the earlier double-nested project layout is gone.

## Toolchain

The 2026-10-17 checks used Flutter 3.38.5, Dart 3.10.4, Visual Studio 2022 C++, and
Inno Setup 6.6.1 on Windows x64. Use the checked-in `pubspec.lock` for package
resolution. A JDK and Android SDK/build-tools are needed only to rebuild the
Android helper.

```powershell
flutter pub get
.\scripts\fetch-windows-runtime.ps1
flutter run -d windows
```

The runtime script downloads the official scrcpy 3.3.3 Windows x64 release:
<https://github.com/Genymobile/scrcpy/releases/tag/v3.3.3>. Its archive SHA-256 is
`4B458D33D0436688C69875CD267CAE6FA8BE08AA3C17772EDF3A940A3DC4B17E`.
It restores ADB and the adjacent DLLs as well as scrcpy and its dependencies.
The project-specific waiting `scrcpy-noconsole.vbs` is preserved.
Downloaded binaries are excluded from source control. Downloads use the normal
PowerShell networking environment, including an explicitly configured proxy.

## Checks

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test
```

See [testing.md](testing.md) for hardware and native tests. Do not run the
real-device tests against an unrelated device; their selected serial is explicit.

## Windows release

```powershell
flutter build windows --release
& 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' .\setup_script.iss
```

The complete release is under `build/windows/x64/runner/Release/`. It includes
`shirabox.exe`, Flutter/plugin DLLs, `data/app.so`, ICU/assets, `assets/server.jar`,
and `data/scrcpy/`. Flutter Dart changes can replace `data/app.so` without changing
the native EXE timestamp. Always distribute the whole bundle or installer.

The installer is written to `dist/Shirabox_Setup_v0.9.0.exe`. `dist/` is local
output and is excluded from Git. Version metadata currently lives in both
`pubspec.yaml` and `setup_script.iss`; update both for a release version change.

## Android helper

```powershell
.\android-helper\build.bat
Get-FileHash .\android-helper\build\server.jar, .\assets\server.jar
```

`build.bat` compiles Java 8 bytecode, converts to DEX with minimum API 21,
validates the JAR, then publishes `android-helper/build/server.jar` and
`assets/server.jar`. The latter is the packaged artifact kept in Git.

Tool lookup order:

- Java: `JAVA_HOME`, `JAVA_BIN`, Android Studio JBR, then PATH.
- SDK: `ANDROID_SDK_ROOT`, `ANDROID_HOME`, then the normal local Android SDK.
- Optional explicit overrides: `ANDROID_JAR` and `BUILD_TOOLS`.

The newest discoverable SDK platform/build-tools are selected unless overridden.
An equal local JAR hash confirms asset synchronization, not a reproducible build
across JDK/SDK versions. Source/protocol changes require checking both sides of
the protocol in [architecture.md](architecture.md).

## Local output and cleanup

`build/`, `.dart_tool/`, platform `ephemeral/` directories, downloaded runtimes,
helper build products, installer output, and local editor/SDK settings are
generated or machine-specific. `flutter clean` removes Flutter build caches.
The source backup excludes these paths through `.gitignore`.

The local `_cleanup-trash/` contains pre-cleanup samples, obsolete artifacts,
and disposable validation caches. It can be deleted manually and is never
published to GitHub.
There are no supported project files under the old `adb_toolbox/adb_toolbox`
or `java/` locations.
