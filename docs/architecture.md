# Architecture

This document follows the code as of 2026-10-17. The production composition root
is `lib/main.dart`: one `AdbCore` is injected into `AppState`, which exposes the
file, process, and Agent services. Logcat reuses that process service; scrcpy
observes the same selected device. `FileTransferProvider` owns transfer job state
across page navigation.

## Source map

| Area | Main source |
| --- | --- |
| Device discovery, argv runner, system capture | `lib/services/adb_core.dart` |
| Device notification framing and states | `lib/services/adb_device_tracking.dart` |
| Immutable targets and cancellation | `lib/services/operation_context.dart` |
| Process handles and Windows bridge | `lib/services/owned_process.dart` |
| Native process Jobs and pipes | `windows/runner/process_job.cpp` |
| Files, manifests, archives, APK installation | `lib/services/adb_file.dart` |
| Windows-safe download names | `lib/services/local_path_codec.dart` |
| Host ASCII staging | `lib/services/ascii_staging.dart`, `windows/runner/native_staging.cpp` |
| Android helper lifecycle | `lib/services/agent_client.dart` |
| Helper source | `android-helper/AdbAgent.java` |
| Device/settings/app state | `lib/providers/app_state.dart` |
| Transfer jobs | `lib/providers/file_transfer_provider.dart` |
| Logcat parser, retention, filters | `lib/providers/logcat_provider.dart` |
| Logcat rendering and tail anchoring | `lib/pages/logcat_page.dart` |
| scrcpy lifecycle and arguments | `lib/providers/scrcpy_provider.dart` |

## ADB server and discovery

Settings load before tracking begins. Executable resolution tries the configured
ADB path, `adb` on PATH, then `data/scrcpy/adb.exe` beside the application.
Changing the configured path restarts the tracker.

`ensureServerStarted()` runs only the `adb start-server` client with parent-only
ownership. Concurrent startups for one executable share the same future. The
starter still has bounded output, a timeout, and runtime cancellation.

This exception is required: on Windows, a daemon started by an ADB client inside
a kill-on-close Job inherits that Job. Releasing the client's Job can terminate
the newly started shared server. Ordinary ADB commands, Agent launchers, and
scrcpy retain process-tree ownership. Do not put the shared server bootstrap back
inside a per-command Job or stop the global server during routine cleanup.

The tracker connects to the server's smart socket and sends
`0012host:track-devices`. It decodes `OKAY`/`FAIL` and hexadecimal length-framed
snapshots across arbitrary TCP chunk boundaries. A change notification does not
spawn another `adb devices` process. Closed connections retry after one second;
a transient socket failure does not publish a fabricated empty device list.
`unauthorized` and `offline` states produce diagnostic messages; only `device`
entries are selectable targets.

Wireless connect first resolves ADB and starts the server, then runs a host-level
`adb connect` without a selected-device `-s`. The dialog accepts an IP and
connection port. Android's initial pairing-code workflow is not implemented.
History metadata uses a one-shot list query instead of starting extra trackers.

## Commands and cancellation

`DeviceTarget` captures the serial, device-session epoch, executable generation,
and executable path. `OperationContext` adds cancellation, optional deadlines,
and an awaited LIFO cleanup stack. Device switches invalidate device-scoped
operations; ADB path changes invalidate work for the old executable.

Structured APIs pass host arguments as a list with no command shell. Remote shell
scripts use `quoteRemoteShellArg`. The default buffered-command timeout is
30 seconds; captures retain at most 16 MiB per stream. Legacy string-command,
`ERROR:` sentinel, and `startRawProcess` APIs remain for compatibility; new work
uses structured owned APIs.

On Windows, `OwnedProcessRunner` creates a child suspended, assigns it to a private
kill-on-close Job, attaches output consumers, then resumes it. Native workers
bridge stdio through the UI message loop. Pending native and pre-listener Dart
output buffers are bounded to 1 MiB per stream. Cancellation addresses the owned
Job and awaits confirmed exit. Remote cleanup remains best-effort if a device
has disconnected.

## Files and installation

Directory listing uses NUL-framed type/path records and pages of 256 entries.
The UI guards results by request generation and device session, cancels obsolete
scans, and renders early pages. Listing defaults are 100,000 entries and 64 KiB
per field.

Recursive transfer scans a manifest before publication. Defaults are depth 32,
50,000 entries, 16 GiB per file, and 50 GiB total. The current UI rejects symlinks
and special entries. Upload builds a hidden remote staging tree; download builds
a same-parent local tree with Windows-safe, collision-free descendant names.
Success renames the complete destination; failure or cancellation cleans staging.
Existing local download destinations are not silently overwritten.

Local enumeration reuses entity types from `Directory.list(followLinks: false)`
instead of repeating every metadata lookup. Upload groups small ASCII files in
one remote directory into batches of up to 32 files, 4 MiB, and a 12,000-character
argument budget. Large and non-ASCII files use individual pushes. The Unicode
fallback avoids a reproduced platform-tools multi-source filename problem.
Progress is best-effort; persistent resume, transfer history, and ETA are absent.

Long/non-ASCII host APK paths use an ASCII temporary directory created through
the native Windows staging channel. Staging does not launch PowerShell or shell
utilities. Archive decoding runs outside the UI isolate, uses generated ASCII
entry names, and preflights ZIP structure and allocation limits. ZIP64,
bundletool APKS containing `toc.pb`, and XAPK/OBB payloads are rejected.

The install dialog passes one operation through a batch. Stop terminates the
active command, prevents later items, abandons unfinished package sessions, and
cleans staging. A package-session install reaches 100% only after commit.
Android Package Manager decides APK acceptance; Shirabox has no independent
publisher-signature trust policy. APK/APKS export stages output before renaming.

## Android helper

The maintained source is `android-helper/AdbAgent.java`. It runs as
`com.adb.toolbox.AdbAgent` through `app_process`, binds device loopback port 6000,
and exits when its owning shell stdin closes. Host sessions allocate distinct
random local forwarding ports and probe the protocol before reuse.

| Command byte | Protocol |
| --- | --- |
| `0` | ASCII banner `SHIRABOX_AGENT/1\n` |
| `1` | UTF-8 JSON application records, one per line, then a blank line |
| `2` | Request: uint16 big-endian package-name byte length and UTF-8 bytes; response: uint32 big-endian PNG length and PNG bytes |
| `3` | Legacy one-byte ping response `3` |

App listing requires the blank terminator; partial results are not committed.
Icons fit within 96 pixels while preserving aspect ratio. The helper bounds its
worker pool and socket reads. Client shutdown handles late startup completion
and cleans its sockets, launcher, forward, JAR, and remote helper.

## Logcat and scrcpy

Logcat captures `threadtime` and preserves unparsed lines. It retains at most
30,000 entries and 12,000 pending lines, processes up to 1,200 lines per 80 ms
batch, and reports dropped input. New entries are filtered once; changing the
filter rescans the bounded retained ring. Filters include levels, regex, case
sensitivity, quoted terms, exclusions, tag/message/PID/TID fields, and AND terms.
An invalid expression preserves the last valid filter.

Rendering uses fixed-height virtualized reverse rows: offset zero is the live
tail. Scrolling away pauses follow; resume returns to zero. Separate selectors
isolate control/status/list rebuilds. JSON export writes the visible snapshot.

scrcpy receives the captured selected serial. Its waiting VBS launcher and
descendants belong to an owned Job; Stop/disposal cancel only handles started by
Shirabox. External scrcpy windows are not discovered or globally terminated.

## Rules for future changes

- Reuse the injected core and capture the target at operation start.
- Drain output, keep work off page-wide rebuild paths, and retain ownership until exit.
- Keep shared ADB server lifetime separate from individual command cleanup.
- Reuse staging/finalization and cancellation paths; show 100% after success.
- Add focused regression coverage for changed behavior and update these docs.
- Refactor the large `AppState` or legacy APIs when a feature needs it; avoid a
  parallel controller framework solely for cleanup.
