# Shirabox

Shirabox is a Windows-first Flutter desktop toolbox for Android devices over ADB.
It includes application management, file and folder transfer, a filtered live
Logcat viewer, system and shell tools, UI inspection, and scrcpy integration.

The current version is `0.9.0+1`. Windows x64 is the maintained desktop target.
The other platform directories are Flutter scaffolding and are not verified
release targets. The interface supports English, Simplified Chinese,
Traditional Chinese, and Japanese.

## Run from source

Install Flutter and Visual Studio's Desktop development with C++ workload, then
run these commands from the repository root in PowerShell:

```powershell
flutter pub get
.\scripts\fetch-windows-runtime.ps1
flutter run -d windows
```

The setup script restores the pinned upstream scrcpy 3.3.3 Windows runtime,
including ADB. Downloaded executables and libraries are excluded from Git.
The Android helper is already packaged as `assets/server.jar`; rebuilding it
requires a JDK and Android SDK.

## Repository layout

```text
lib/                    Flutter pages, providers, and ADB services
test/                   Unit/widget tests and opt-in device/native smoke tests
windows/runner/         Native Windows process ownership and ASCII staging
windows/resources/     Downloaded scrcpy runtime and project launcher
assets/server.jar       Packaged Android helper
android-helper/         Maintained Java helper source and build script
scripts/                Dependency setup
docs/                   Current architecture, development, testing, and roadmap
setup_script.iss        Windows installer definition
```

Build output, installers, caches, local editor settings, and old local samples
are not part of the source repository.

## Documentation

- [Architecture and subsystem behavior](docs/architecture.md)
- [Development, dependencies, and packaging](docs/development.md)
- [Verification and regression tests](docs/testing.md)
- [Remaining work](docs/roadmap.md)

The technical documents describe the current code. Completed tasks and obsolete
investigation notes are removed instead of accumulating as a second backlog.

## Current behavior and limits

- USB devices and already-paired wireless devices are tracked automatically.
  The wireless dialog connects to a supplied IP and connection port; it does not
  provide Android wireless pairing-code entry.
- Stop cancels active owned ADB work. The shared ADB server has a separate
  lifetime and survives individual command cleanup.
- File and folder transfers expose progress and publish staged destinations only
  after success. Small ASCII uploads are batched; Unicode paths use the stable
  single-file route.
- APK installation uses Android Package Manager's acceptance result. Simple APK
  archives are supported; bundletool APKS variants and XAPK/OBB payloads are
  explicitly rejected.
- A release must contain the complete Windows bundle, or be installed with the
  generated installer. Copying only `shirabox.exe` is insufficient.
