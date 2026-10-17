# Windows runtime

Run `./scripts/fetch-windows-runtime.ps1` from the repository root before a
Windows build. It downloads the official scrcpy 3.3.3 Windows x64 package and
checks the release archive SHA-256. Runtime executables and libraries are local
dependencies and are excluded from Git.

`scrcpy-noconsole.vbs` is the project-specific launcher. It waits for scrcpy so
the toolbox can own and stop that process tree. The download script preserves it.

Upstream: <https://github.com/Genymobile/scrcpy/releases/tag/v3.3.3>.
