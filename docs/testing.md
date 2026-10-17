# Verification

The current connection fix was checked on 2026-10-17. These results are scoped
to the tests below; they are not a claim of compatibility with every device.

| Check | Result |
| --- | --- |
| Dart format | Clean |
| Flutter analyze | No issues |
| Flutter tests | 81 passed; 3 opt-in smoke tests skipped by default |
| Shared ADB server smoke, system platform-tools 37.0.0 | Passed |
| Shared ADB server smoke, bundled platform-tools 36.0.0 | Passed |
| Native argv/stdio/Job descendant smoke, MSVC `/W4 /WX` | Passed |
| Windows release and Inno installer | Built successfully |

## Connection regression

`test/adb_device_tracking_test.dart` covers fragmented and combined tracker
frames, unauthorized/offline states, shared bootstrap coalescing, device changes,
reconnection without false empty lists, wireless bootstrap ordering, settings
initialization ordering, and ADB-path tracker replacement.

The Windows failure was reproduced on an isolated server port: native
kill-on-close Job startup returned success, then releasing the Job removed the
new ADB daemon. Starting the shared daemon separately allowed it to survive
subsequent owned-command cleanup.

The opt-in real-ADB smoke creates a private server port, starts the daemon through
the production bootstrap, reads a tracker snapshot, queries devices, disposes
the runtime, verifies the daemon still accepts connections, then stops only that
private server:

```powershell
$env:SHIRABOX_ADB_SERVER_SMOKE = 'C:\path\to\platform-tools\adb.exe'
flutter test test/adb_server_smoke_test.dart
Remove-Item Env:SHIRABOX_ADB_SERVER_SMOKE
```

This test uses real ADB but does not assert that a particular physical device is
connected. USB unplug/replug and wireless reconnect with the corrected UI still
need normal device use; the currently running old installer must be replaced
before evaluating the fix.

## Real-device tests

```powershell
$env:SHIRABOX_DEVICE_SMOKE_SERIAL = '<selected-device-serial>'
flutter test test/device_recursive_transfer_smoke_test.dart
flutter test test/device_logcat_smoke_test.dart
Remove-Item Env:SHIRABOX_DEVICE_SMOKE_SERIAL
```

The folder test creates a uniquely named tree under `/sdcard/Download`, transfers
it in both directions, checks content/progress, and cleans test staging. It
includes 40 small ASCII files, nested/empty directories, Unicode names, and empty
files. The Logcat test waits for structured `threadtime` output and checks Stop.

Historical hardware coverage: Pixel 9, Android 16/API 36 folder round trip on
2026-08-01 and Logcat capture on 2026-07-20. Those physical-device tests were not
rerun for the 2026-10-17 connection change.

## Native process smoke

From a Visual Studio x64 developer shell:

```powershell
New-Item -ItemType Directory -Path build/native-check -Force
cl /nologo /std:c++17 /EHsc /W4 /WX test/native/process_job_smoke.cpp windows/runner/process_job.cpp /Fobuild/native-check/ /Febuild/native-check/process_job_smoke.exe
.\build\native-check\process_job_smoke.exe
```

It checks exact Windows arguments, stdin/stdout/stderr, suspended launch, and
termination of a parent plus its immediate child. The optional
`--adb-bootstrap-probe <adb.exe> <private-port>` mode reproduces why a shared ADB
daemon must not be started in that Job; it is a diagnostic, not a success check
for the fixed bootstrap path.

## Performance observations

`test/transfer_performance_test.dart` reports local manifest scanning and remote
manifest decoding for 2,000 entries. Earlier standalone local runs measured
roughly 295-357 ms for 2,000 tiny files and 15-22 ms for decoding. Treat these as
workstation observations; parallel test scheduling and filesystem cache affect
them. They are not CI thresholds or measured end-to-end transfer throughput.
