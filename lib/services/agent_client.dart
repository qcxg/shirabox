import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'adb_core.dart';
import 'ascii_staging.dart';
import 'owned_process.dart';

class AgentClient {
  AgentClient(this._adb);

  final AdbCore _adb;
  final Random _random = Random.secure();
  final Map<String, _AgentSession> _sessions = {};
  final Map<String, Future<_AgentSession>> _startingSessions = {};
  final Set<int> _allocatedPorts = {};

  static const int _remotePort = 6000;
  static const String _remoteJarPath = '/data/local/tmp/server.jar';
  static const String _agentClass = 'com.adb.toolbox.AdbAgent';
  static const String _protocolBanner = 'SHIRABOX_AGENT/1';
  static const int _maxIconBytes = 16 * 1024 * 1024;
  static const int _maxProcessDiagnosticBytes = 4096;

  int _lifecycleGeneration = 0;
  bool _closed = false;
  Future<void>? _stopFuture;

  /// Ensures that [serial] owns a dedicated local forwarding port.
  ///
  /// Keeping one port per device is deliberate: an icon request from an old
  /// device session can finish harmlessly, but it can never be rerouted to the
  /// newly selected device.
  Future<void> ensureAgentRunning({String? serial}) async {
    if (_closed) {
      throw const AdbCommandException('Android helper client is closed.');
    }
    final targetSerial = serial ?? _adb.targetSerial;
    if (targetSerial == null || targetSerial.trim().isEmpty) {
      throw const AdbCommandException('No target device selected.');
    }
    await _ensureSession(targetSerial.trim());
  }

  Future<_AgentSession> _ensureSession(String serial) {
    if (_closed) {
      return Future<_AgentSession>.error(
        const AdbCommandException('Android helper client is closed.'),
      );
    }
    final inFlight = _startingSessions[serial];
    if (inFlight != null) return inFlight;

    final generation = _lifecycleGeneration;
    late final Future<_AgentSession> operation;
    operation = _startOrReuseSession(serial, generation).whenComplete(() {
      if (identical(_startingSessions[serial], operation)) {
        _startingSessions.remove(serial);
      }
    });
    _startingSessions[serial] = operation;
    return operation;
  }

  Future<_AgentSession> _startOrReuseSession(
    String serial,
    int generation,
  ) async {
    final existing = _sessions[serial];
    if (existing != null) {
      final healthy = await _probe(existing);
      _throwIfSessionStopped(existing, generation);
      if (healthy) {
        await _removeRemoteJar(serial);
        _throwIfSessionStopped(existing, generation);
        return existing;
      }
      await _disposeSession(existing, killRemote: true);
      _throwIfStopped(generation);
    }

    var session = _AgentSession(serial, _allocatePort());

    // A random host port can be occupied by another process. Retry with a new
    // one without ever sharing a port between device sessions.
    var forwardOwned = false;
    for (var attempt = 0; attempt < 5; attempt++) {
      _throwIfStopped(generation);
      try {
        await _adb.runSafe(
          [
            'forward',
            '--no-rebind',
            'tcp:${session.localPort}',
            'tcp:$_remotePort',
          ],
          serial: serial,
        );
        forwardOwned = true;
        session.forwardOwned = true;
        break;
      } catch (error) {
        _allocatedPorts.remove(session.localPort);
        _throwIfStopped(generation);
        if (attempt == 4) {
          throw AdbCommandException(
            'Unable to allocate an ADB forward for $serial: $error',
          );
        }
        session = _AgentSession(serial, _allocatePort());
      }
    }

    // Register ownership before any further await. stop() can now always see
    // and remove a forward acquired by an in-flight startup.
    _sessions[serial] = session;
    try {
      _throwIfSessionStopped(session, generation);

      // Probe before launch. This avoids an eight-second wait and duplicate
      // app_process instance when a healthy helper is already running.
      final alreadyRunning = await _probe(session);
      _throwIfSessionStopped(session, generation);
      if (alreadyRunning) {
        await _removeRemoteJar(serial);
        _throwIfSessionStopped(session, generation);
        return session;
      }

      await _pushServerJar(session, generation);
      _throwIfSessionStopped(session, generation);

      // Replace an older helper that does not implement the version handshake.
      try {
        await _adb.runSafe(
          ['shell', 'pkill', '-f', _agentClass],
          serial: serial,
          timeout: const Duration(seconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
      } catch (_) {}
      _throwIfSessionStopped(session, generation);

      final launcher = await _adb.startOwnedProcess([
        'shell',
        'export CLASSPATH=$_remoteJarPath && '
            'app_process /data/local/tmp $_agentClass',
      ], serial: serial);
      session.launcher = launcher;
      try {
        _throwIfSessionStopped(session, generation);
      } catch (_) {
        await _stopLauncher(session);
        rethrow;
      }
      Object? launchError;
      session.stdoutSubscription = launcher.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
        (_) {},
        onError: (Object error) {
          launchError = error;
        },
      );
      session.stderrSubscription = launcher.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        final combined = '${launchError ?? ''}\n$line'.trim();
        launchError = combined.length > 4096
            ? combined.substring(combined.length - 4096)
            : combined;
      });
      unawaited(launcher.done.then((exit) {
        session.launcherExited = true;
        session.launcherExitCode = exit.exitCode;
      }));

      var ready = false;
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline)) {
        _throwIfSessionStopped(session, generation);
        final healthy = await _probe(session);
        _throwIfSessionStopped(session, generation);
        if (healthy) {
          ready = true;
          break;
        }
        if (session.launcherExited) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      _throwIfSessionStopped(session, generation);
      if (!ready) {
        throw AdbCommandException(
          launchError == null
              ? 'Android helper did not become ready before the deadline.'
              : 'Android helper failed to start '
                  '(exit ${session.launcherExitCode ?? 'unknown'}): '
                  '$launchError',
        );
      }

      await _removeRemoteJar(serial);
      _throwIfSessionStopped(session, generation);
      return session;
    } catch (_) {
      if (identical(_sessions[serial], session)) {
        _sessions.remove(serial);
      }
      if (forwardOwned) session.forwardOwned = true;
      await _disposeSession(session, killRemote: true);
      // A Process.start() that completed after stop() disposed the session can
      // otherwise launch a helper or recreate a partial JAR after the first
      // cleanup. This second, ordered cleanup runs only after startup unwinds.
      await _killRemoteAgent(serial);
      await _removeRemoteJar(serial);
      rethrow;
    }
  }

  Future<void> _pushServerJar(
    _AgentSession session,
    int generation,
  ) async {
    Directory? stagingDir;
    OwnedCommandHandle? pushProcess;
    Future<List<String>>? diagnosticsFuture;
    _throwIfSessionStopped(session, generation);
    stagingDir = await createAdbSafeTempDirectory('shirabox_agent_');
    _throwIfSessionStopped(session, generation);
    final tempJar = File(p.join(stagingDir.path, 'server.jar'));
    try {
      try {
        final data = await rootBundle.load('assets/server.jar');
        _throwIfSessionStopped(session, generation);
        await tempJar.writeAsBytes(data.buffer.asUint8List(), flush: true);
      } on AdbCommandException {
        rethrow;
      } catch (_) {
        final local = File('assets/server.jar');
        if (!await local.exists()) {
          throw const AdbCommandException('assets/server.jar is missing.');
        }
        _throwIfSessionStopped(session, generation);
        await local.copy(tempJar.path);
      }
      _throwIfSessionStopped(session, generation);

      pushProcess = await _adb.startOwnedProcess(
        ['push', tempJar.path, _remoteJarPath],
        serial: session.serial,
      );
      session.startupProcess = pushProcess;
      diagnosticsFuture = Future.wait([
        _captureProcessDiagnostic(pushProcess.stdout),
        _captureProcessDiagnostic(pushProcess.stderr),
      ]);
      _throwIfSessionStopped(session, generation);

      int exitCode;
      try {
        final exit = await pushProcess.done.timeout(
          const Duration(minutes: 2),
        );
        exitCode = exit.exitCode;
      } on TimeoutException {
        await _stopStartupProcess(session);
        throw const AdbCommandException(
          'Timed out while uploading the Android helper.',
        );
      }
      if (identical(session.startupProcess, pushProcess)) {
        session.startupProcess = null;
      }
      final diagnostics = await diagnosticsFuture;
      _throwIfSessionStopped(session, generation);
      if (exitCode != 0) {
        final stderr = diagnostics[1].trim();
        final stdout = diagnostics[0].trim();
        final detail = stderr.isNotEmpty ? stderr : stdout;
        throw AdbCommandException(
          detail.isEmpty
              ? 'ADB failed to upload the Android helper (exit $exitCode).'
              : 'ADB failed to upload the Android helper: $detail',
          exitCode: exitCode,
          arguments: ['push', tempJar.path, _remoteJarPath],
        );
      }
    } finally {
      if (pushProcess != null &&
          identical(session.startupProcess, pushProcess)) {
        await _stopStartupProcess(session);
      }
      if (diagnosticsFuture != null) {
        try {
          await diagnosticsFuture.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      try {
        await stagingDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<String> _captureProcessDiagnostic(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    var remaining = _maxProcessDiagnosticBytes;
    await for (final chunk in stream) {
      if (remaining <= 0) continue;
      final take = min(remaining, chunk.length);
      bytes.add(chunk.sublist(0, take));
      remaining -= take;
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Stream<String> fetchAppListRawStream(String serial) async* {
    final session = await _ensureSession(serial);
    Socket? socket;
    try {
      socket = await _connectWithRetry(session);
      socket.add([1]);
      await socket.flush();
      final stream = socket
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 30));
      var terminated = false;
      await for (final line in stream) {
        if (line.isEmpty) {
          terminated = true;
          break;
        }
        if (line.trim().isNotEmpty) yield line;
      }
      if (!terminated) {
        throw const FormatException(
          'Android helper app list ended before its terminator.',
        );
      }
    } finally {
      _releaseSocket(session, socket);
    }
  }

  Future<Uint8List?> fetchIcon(String pkg, {required String serial}) async {
    // App-list loading created this session. Do not start/rebind a helper from
    // a stale icon task after the user has switched devices.
    final session = _sessions[serial];
    if (session == null) return null;

    Socket? socket;
    try {
      socket = await _connectWithRetry(session);
      socket.add([2]);
      final packageBytes = utf8.encode(pkg);
      if (packageBytes.length > 0xffff) return null;
      socket.add([
        packageBytes.length >> 8,
        packageBytes.length & 0xff,
        ...packageBytes,
      ]);
      await socket.flush();
      final buffer = await _readExact(socket);
      return buffer.isNotEmpty ? buffer : null;
    } catch (_) {
      return null;
    } finally {
      _releaseSocket(session, socket);
    }
  }

  Future<bool> _probe(_AgentSession session) async {
    if (!_isSessionActive(session)) return false;
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        session.localPort,
        timeout: const Duration(milliseconds: 700),
      );
      if (!_isSessionActive(session)) return false;
      session.sockets.add(socket);
      socket.add([0]);
      await socket.flush();
      final response = await socket
          .cast<List<int>>()
          .transform(const AsciiDecoder(allowInvalid: false))
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 1));
      return response == _protocolBanner;
    } catch (_) {
      return false;
    } finally {
      _releaseSocket(session, socket);
    }
  }

  Future<Socket> _connectWithRetry(_AgentSession session) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      _throwIfSessionUnavailable(session);
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          session.localPort,
          timeout: const Duration(seconds: 1),
        );
        if (!_isSessionActive(session)) {
          socket.destroy();
          _throwIfSessionUnavailable(session);
        }
        session.sockets.add(socket);
        return socket;
      } catch (error) {
        _throwIfSessionUnavailable(session);
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    throw AdbCommandException(
      'Unable to connect to the Android helper for ${session.serial}: '
      '$lastError',
    );
  }

  Future<Uint8List> _readExact(Socket socket) async {
    final completer = Completer<Uint8List>();
    final chunks = <int>[];
    int? expectedLength;
    late final StreamSubscription<List<int>> subscription;

    subscription = socket.listen((data) {
      if (completer.isCompleted) return;
      chunks.addAll(data);
      if (expectedLength == null && chunks.length >= 4) {
        final byteData =
            ByteData.sublistView(Uint8List.fromList(chunks.sublist(0, 4)));
        expectedLength = byteData.getUint32(0);
        chunks.removeRange(0, 4);
        if (expectedLength! > _maxIconBytes) {
          completer.completeError(
            const FormatException('Agent icon frame exceeds the size limit.'),
          );
          unawaited(subscription.cancel());
          return;
        }
      }
      if (expectedLength != null && chunks.length >= expectedLength!) {
        completer.complete(
          Uint8List.fromList(chunks.sublist(0, expectedLength!)),
        );
        unawaited(subscription.cancel());
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }, onDone: () {
      if (!completer.isCompleted) {
        completer.completeError(
          const FormatException('Agent icon frame ended before completion.'),
        );
      }
    });

    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      await subscription.cancel();
    }
  }

  int _allocatePort() {
    for (var attempt = 0; attempt < 100; attempt++) {
      final port = 49152 + _random.nextInt(16384);
      if (_allocatedPorts.add(port)) return port;
    }
    throw const AdbCommandException('Unable to reserve a local helper port.');
  }

  void _throwIfStopped(int generation) {
    if (_closed || generation != _lifecycleGeneration) {
      throw const AdbCommandException('Android helper startup was cancelled.');
    }
  }

  void _throwIfSessionStopped(_AgentSession session, int generation) {
    _throwIfStopped(generation);
    if (!_isSessionActive(session)) {
      throw const AdbCommandException(
        'Android helper startup was cancelled.',
      );
    }
  }

  void _throwIfSessionUnavailable(_AgentSession session) {
    if (!_isSessionActive(session)) {
      throw const AdbCommandException('Android helper session is closed.');
    }
  }

  bool _isSessionActive(_AgentSession session) =>
      !_closed &&
      session.disposal == null &&
      identical(_sessions[session.serial], session);

  void _releaseSocket(_AgentSession session, Socket? socket) {
    if (socket == null) return;
    session.sockets.remove(socket);
    socket.destroy();
  }

  void _destroySessionSockets(_AgentSession session) {
    final sockets = session.sockets.toList(growable: false);
    session.sockets.clear();
    for (final socket in sockets) {
      socket.destroy();
    }
  }

  Future<void> _stopStartupProcess(_AgentSession session) async {
    final process = session.startupProcess;
    if (process == null) return;
    session.startupProcess = null;
    await _terminateProcess(process);
  }

  Future<void> _terminateProcess(OwnedCommandHandle process) async {
    try {
      await process.cancel();
    } catch (_) {
      // The owned runner already escalates to the process fallback when the
      // native Job termination is unavailable.
    }
  }

  Future<void> _removeRemoteJar(String serial) async {
    try {
      await _adb.runSafe(
        ['shell', 'rm', '-f', '--', _remoteJarPath],
        serial: serial,
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  Future<void> _killRemoteAgent(String serial) async {
    try {
      await _adb.runSafe(
        ['shell', 'pkill', '-f', _agentClass],
        serial: serial,
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  Future<void> _removeForward(_AgentSession session) async {
    try {
      await _adb.runSafe(
        ['forward', '--remove', 'tcp:${session.localPort}'],
        serial: session.serial,
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  Future<void> _disposeSession(
    _AgentSession session, {
    required bool killRemote,
  }) {
    final existing = session.disposal;
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = (() async {
      _destroySessionSockets(session);
      await _stopStartupProcess(session);
      if (killRemote) {
        await _killRemoteAgent(session.serial);
      }

      await _stopLauncher(session);
      await _removeRemoteJar(session.serial);
      if (session.forwardOwned) {
        await _removeForward(session);
        session.forwardOwned = false;
      }
      _allocatedPorts.remove(session.localPort);
      if (identical(_sessions[session.serial], session)) {
        _sessions.remove(session.serial);
      }
    })();
    session.disposal = operation;
    return operation;
  }

  Future<void> _stopLauncher(_AgentSession session) async {
    final launcher = session.launcher;
    session.launcher = null;
    if (launcher != null) {
      await _terminateProcess(launcher);
    }
    try {
      await session.stdoutSubscription?.cancel();
    } catch (_) {}
    try {
      await session.stderrSubscription?.cancel();
    } catch (_) {}
    session.stdoutSubscription = null;
    session.stderrSubscription = null;
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    _closed = true;
    _lifecycleGeneration++;
    final pendingStarts = _startingSessions.values.toList(growable: false);
    final completer = Completer<void>();
    _stopFuture = completer.future;

    unawaited(() async {
      try {
        final active = _sessions.values.toSet().toList(growable: false);
        await Future.wait(
          active.map((session) => _disposeSession(session, killRemote: true)),
        );
        await Future.wait(pendingStarts.map((pending) async {
          try {
            await pending;
          } catch (_) {}
        }));
        final lateSessions = _sessions.values.toSet().toList(growable: false);
        await Future.wait(
          lateSessions
              .map((session) => _disposeSession(session, killRemote: true)),
        );
        _sessions.clear();
        _allocatedPorts.clear();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }());
    return completer.future;
  }
}

class _AgentSession {
  _AgentSession(this.serial, this.localPort);

  final String serial;
  final int localPort;
  bool forwardOwned = false;
  bool launcherExited = false;
  int? launcherExitCode;
  OwnedCommandHandle? startupProcess;
  OwnedCommandHandle? launcher;
  final Set<Socket> sockets = {};
  StreamSubscription<String>? stdoutSubscription;
  StreamSubscription<String>? stderrSubscription;
  Future<void>? disposal;
}
