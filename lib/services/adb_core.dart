import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adb_device_tracking.dart';
import 'operation_context.dart';
import 'owned_process.dart';

class AdbCore {
  static const Duration _defaultCommandTimeout = Duration(seconds: 30);
  static const int _maxCapturedOutputBytes = 16 * 1024 * 1024;

  String _adbPath;
  final OwnedProcessRunner _ownedProcessRunner;
  final OwnedProcessRunner _serverProcessRunner;
  final int adbServerPort;
  Future<void>? _serverStartup;
  String? _serverStartupExecutable;
  final OperationRegistry _operations = OperationRegistry();
  int _availabilityGeneration = 0;
  int _deviceSessionEpoch = 0;
  int _adbExecutableGeneration = 0;
  Future<void> _pendingInvalidation = Future<void>.value();

  String get executablePath => _adbPath.isEmpty ? 'adb' : _adbPath;

  bool _isValid = false;
  bool get isValid => _isValid;
  bool _isFallback = false;
  bool get isFallback => _isFallback; // 用于 UI 显示 "Fallback: App Default"

  String? _targetSerial;

  String? get targetSerial => _targetSerial;
  int get activeOperationCount => _operations.activeCount;
  Future<void> get pendingOperationInvalidation => _pendingInvalidation;
  DeviceTarget get targetSnapshot => captureTarget();

  AdbCore({
    String adbPath = 'adb',
    bool checkOnCreate = true,
    OwnedProcessRunner? ownedProcessRunner,
    ProcessLauncher? serverLauncher,
    this.adbServerPort = 5037,
  })  : _adbPath = adbPath.trim().isEmpty ? 'adb' : adbPath.trim(),
        _ownedProcessRunner = ownedProcessRunner ?? OwnedProcessRunner(),
        _serverProcessRunner = OwnedProcessRunner(
          launcher: serverLauncher ?? const IoProcessLauncher(),
          jobController: const NoopProcessJobController(),
        ) {
    RangeError.checkValueInInterval(adbServerPort, 1, 65535, 'adbServerPort');
    if (checkOnCreate) unawaited(checkAvailability());
  }

  void setTargetDevice(String? serial) {
    final trimmed = serial?.trim();
    final normalized = trimmed == null || trimmed.isEmpty ? null : trimmed;
    if (_targetSerial == normalized) return;
    _targetSerial = normalized;
    _deviceSessionEpoch++;
    final current = captureTarget();
    _queueInvalidation(
      (operation) =>
          operation.target.deviceScoped &&
          !operation.target.isCurrentAgainst(current),
      OperationCancelReason.deviceTargetChanged,
    );
  }

  void setAdbPath(String path) {
    _setAdbExecutable(path.trim().isEmpty ? 'adb' : path.trim());
    unawaited(checkAvailability());
  }

  DeviceTarget captureTarget({
    String? serial,
    bool deviceScoped = true,
    String? adbExecutable,
  }) {
    final explicit = serial?.trim();
    final selected = explicit != null && explicit.isNotEmpty
        ? explicit
        : (deviceScoped ? _targetSerial : null);
    return DeviceTarget(
      serial: selected,
      sessionEpoch: _deviceSessionEpoch,
      adbExecutableGeneration: _adbExecutableGeneration,
      adbExecutable: adbExecutable ?? executablePath,
      deviceScoped: deviceScoped,
    );
  }

  bool isTargetCurrent(DeviceTarget target) =>
      target.isCurrentAgainst(captureTarget());

  OperationContext beginOperation({
    DeviceTarget? target,
    String? serial,
    bool deviceScoped = true,
    Duration? deadline,
  }) {
    return _operations.begin(
      target:
          target ?? captureTarget(serial: serial, deviceScoped: deviceScoped),
      deadline: deadline == null ? null : DateTime.now().add(deadline),
    );
  }

  Future<void> cancelActiveOperations([
    OperationCancelReason reason = OperationCancelReason.requested,
  ]) =>
      _operations.cancelAll(reason);

  Future<void> disposeRuntime() {
    _availabilityGeneration++;
    return cancelActiveOperations(OperationCancelReason.runtimeShutdown);
  }

  void _setAdbExecutable(String path) {
    if (_adbPath == path) return;
    _adbPath = path;
    _adbExecutableGeneration++;
    final current = captureTarget();
    _queueInvalidation(
      (operation) => !operation.target.isCurrentAgainst(current),
      OperationCancelReason.adbExecutableChanged,
    );
  }

  void _queueInvalidation(
    bool Function(OperationContext operation) test,
    OperationCancelReason reason,
  ) {
    final previous = _pendingInvalidation;
    final current = _operations.cancelWhere(test, reason);
    _pendingInvalidation = Future.wait<void>(<Future<void>>[previous, current]);
  }

  Future<bool> checkAvailability() async {
    final generation = ++_availabilityGeneration;
    final configuredPath = _adbPath;

    bool commit({
      required bool valid,
      String? resolvedPath,
      bool fallback = false,
    }) {
      if (generation == _availabilityGeneration) {
        if (resolvedPath != null) _setAdbExecutable(resolvedPath);
        _isValid = valid;
        _isFallback = fallback;
      }
      return valid;
    }

    // 1. 如果手动设置了路径且不为空，先尝试它
    if (configuredPath != 'adb') {
      if (await _tryPath(configuredPath)) {
        return commit(valid: true, resolvedPath: configuredPath);
      }
    }

    // 2. 尝试系统默认 'adb'
    if (await _tryPath('adb')) {
      return commit(valid: true, resolvedPath: 'adb');
    }

    // 3. 尝试内置回落路径 (data/scrcpy/adb.exe)
    String exeDir = File(Platform.resolvedExecutable).parent.path;
    // 简单点，直接拼正式版路径
    String officialBundled = "$exeDir\\data\\scrcpy\\adb.exe";
    if (await _tryPath(officialBundled)) {
      return commit(
        valid: true,
        resolvedPath: officialBundled,
        fallback: true,
      );
    }

    return commit(valid: false);
  }

  Future<bool> _tryPath(String path) async {
    final operation = beginOperation(
      target: captureTarget(
        deviceScoped: false,
        adbExecutable: path,
      ),
    );
    try {
      final handle = await startOwnedProcess(
        const <String>['version'],
        includeTarget: false,
        timeout: const Duration(seconds: 5),
        operation: operation,
      );
      final result = await handle.collect();
      return result.exit.reason == OwnedCommandEndReason.exited &&
          result.exit.exitCode == 0 &&
          result.exit.terminationError == null &&
          result.exit.releaseError == null;
    } catch (_) {
      return false;
    } finally {
      await operation.complete();
    }
  }

  /// ADB's shared daemon must outlive the short-lived start-server client.
  /// Attaching that client to a kill-on-close Job also kills its new daemon.
  /// Only this bootstrap uses parent-only ownership; normal commands keep Jobs.
  Future<void> ensureServerStarted() {
    final executable = executablePath;
    if (_serverStartup != null && _serverStartupExecutable == executable) {
      return _serverStartup!;
    }
    _serverStartupExecutable = executable;
    late final Future<void> startup;
    startup = _startSharedServer(executable).whenComplete(() {
      if (identical(_serverStartup, startup)) {
        _serverStartup = null;
        _serverStartupExecutable = null;
      }
    });
    _serverStartup = startup;
    return startup;
  }

  Future<void> _startSharedServer(String executable) async {
    final operation = beginOperation(
      target: captureTarget(deviceScoped: false, adbExecutable: executable),
    );
    try {
      final handle = await _serverProcessRunner.start(
        executable,
        [
          if (adbServerPort != 5037) ...['-P', '$adbServerPort'],
          'start-server'
        ],
        timeout: const Duration(seconds: 15),
      );
      await operation.own(cancel: () async {
        if (!handle.isCompleted) await handle.cancel();
      });
      final result = await handle.collect(maxBytesPerStream: 64 * 1024);
      operation.throwIfCancelled();
      if (result.exit.reason != OwnedCommandEndReason.exited ||
          result.exit.exitCode != 0) {
        final detail = result.stderr.decodeUtf8().trim();
        throw AdbCommandException(
          detail.isEmpty ? 'Unable to start the ADB server.' : detail,
          exitCode: result.exit.exitCode,
        );
      }
    } finally {
      await operation.complete();
    }
  }

  Future<List<String>> listDevices() async => AdbDeviceSnapshot(
        await runText(['devices'], includeTarget: false),
      ).connected;

  Stream<List<String>> trackDevices({void Function(String)? onDiagnostic}) {
    final controller = StreamController<List<String>>();
    Socket? socket;
    Timer? reconnectTimer;
    bool cancelled = false;
    bool connecting = false;
    String? lastDiagnostic;
    String? lastSnapshot;

    void diagnose(String message) {
      if (cancelled || message == lastDiagnostic) return;
      lastDiagnostic = message;
      onDiagnostic?.call(message);
    }

    void scheduleReconnect(void Function() start) {
      if (cancelled || reconnectTimer != null) return;
      reconnectTimer = Timer(const Duration(seconds: 1), () {
        reconnectTimer = null;
        start();
      });
    }

    void start() async {
      if (cancelled || connecting) return;
      connecting = true;
      try {
        if (!await checkAvailability()) {
          throw const AdbCommandException('No working ADB executable found.');
        }
        if (cancelled) return;
        await ensureServerStarted();
        if (cancelled) return;

        final candidate = await Socket.connect(
          '127.0.0.1',
          adbServerPort,
          timeout: const Duration(seconds: 3),
        );
        if (cancelled) {
          candidate.destroy();
          return;
        }
        socket = candidate;
        lastSnapshot = null;
        final decoder = AdbDeviceTrackerDecoder();
        candidate.write('0012host:track-devices');
        candidate.listen((data) {
          if (cancelled || !identical(socket, candidate)) return;
          try {
            for (final snapshot in decoder.add(data)) {
              final diagnostic = snapshot.diagnostic;
              if (diagnostic != null) {
                diagnose(diagnostic);
              } else {
                lastDiagnostic = null;
              }
              final devices = snapshot.connected;
              final key = devices.join('\u0000');
              if (key != lastSnapshot) {
                lastSnapshot = key;
                controller.add(devices);
              }
            }
          } catch (error) {
            diagnose('ADB device tracking failed: $error');
            candidate.destroy();
            socket = null;
            scheduleReconnect(start);
          }
        }, onError: (e) {
          if (cancelled || !identical(socket, candidate)) return;
          diagnose('ADB device tracking failed: $e');
          candidate.destroy();
          socket = null;
          scheduleReconnect(start);
        }, onDone: () {
          if (cancelled || !identical(socket, candidate)) return;
          socket = null;
          scheduleReconnect(start);
        });
      } catch (e) {
        if (cancelled) return;
        diagnose('ADB device tracking failed: $e');
        scheduleReconnect(start);
      } finally {
        connecting = false;
      }
    }

    controller.onListen = start;
    controller.onCancel = () {
      cancelled = true;
      reconnectTimer?.cancel();
      reconnectTimer = null;
      socket?.destroy();
      socket = null;
    };
    return controller.stream;
  }

  /// Legacy string-based entry point.
  ///
  /// New code should use [runRaw], [runText], or [runScript] so argument
  /// boundaries are never reconstructed from a command string.
  @Deprecated('Use runRaw, runText, or runScript with typed arguments.')
  Future<String> run(String command) async {
    try {
      final trimmed = command.trim();
      if (trimmed.isEmpty) return '';

      if (trimmed == 'shell') {
        return await runScript('');
      }
      if (trimmed.startsWith('shell ')) {
        return await runScript(trimmed.substring('shell '.length));
      }

      final args = _splitLegacyCommand(trimmed);
      final hostOnly = const {
        'devices',
        'connect',
        'disconnect',
        'start-server',
        'kill-server',
      }.contains(args.first);
      return await runText(args, includeTarget: !hostOnly);
    } catch (e) {
      return "ERROR: $e";
    }
  }

  /// Runs ADB without a local shell and captures bounded output from both
  /// pipes. An explicit [serial] pins a multi-step job to one device even if
  /// the UI selection changes while the job is running.
  Future<ProcessResult> runRaw(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration timeout = _defaultCommandTimeout,
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    if (args.isEmpty) {
      throw const AdbCommandException('ADB arguments must not be empty.');
    }

    final progressParser = AdbProgressParser();

    void reportProgress(List<int> bytes) {
      if (onProgress == null || bytes.isEmpty) return;
      for (final value in progressParser.addBytes(bytes)) {
        onProgress(value);
      }
    }

    late final OwnedCommandHandle handle;
    try {
      handle = await startOwnedProcess(
        args,
        serial: serial,
        includeTarget: includeTarget,
        timeout: timeout,
        operation: operation,
      );
    } on OperationCancelledException catch (error) {
      throw AdbCommandException(
        'ADB command was cancelled (${error.reason.name}).',
        arguments: args,
      );
    }
    final result = await handle.collect(
      maxBytesPerStream: _maxCapturedOutputBytes,
      onStdoutChunk: reportProgress,
      onStderrChunk: reportProgress,
    );
    if (result.exit.reason == OwnedCommandEndReason.timedOut) {
      throw AdbCommandException(
        'ADB command timed out after ${timeout.inSeconds}s.',
        arguments: handle.arguments,
      );
    }
    if (result.exit.reason == OwnedCommandEndReason.cancelled) {
      final reason = operation?.cancelReason;
      throw AdbCommandException(
        reason == null
            ? 'ADB command was cancelled.'
            : 'ADB command was cancelled (${reason.name}).',
        arguments: handle.arguments,
      );
    }
    final ownershipError =
        result.exit.terminationError ?? result.exit.releaseError;
    if (ownershipError != null) {
      throw AdbCommandException(
        'ADB command exited, but owned process cleanup was not confirmed: '
        '$ownershipError',
        exitCode: result.exit.exitCode,
        arguments: handle.arguments,
      );
    }

    if (result.exit.exitCode == 0 &&
        onProgress != null &&
        progressParser.lastValue < 1) {
      onProgress(1);
    }
    String decode(OwnedCommandCapture capture) {
      var text = capture.decodeUtf8();
      if (capture.truncated) {
        text += '\n[output truncated by Shirabox; '
            '${capture.capturedBytes}/${capture.observedBytes} bytes retained]';
      }
      return text;
    }

    return ProcessResult(
      result.pid,
      result.exit.exitCode,
      decode(result.stdout),
      decode(result.stderr),
    );
  }

  /// Starts an owned ADB process without a host shell. The caller must drain
  /// both output pipes and close/kill the returned process during shutdown.
  Future<Process> startRawProcess(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
  }) {
    if (args.isEmpty) {
      throw const AdbCommandException('ADB arguments must not be empty.');
    }
    final target = _captureInvocationTarget(
      args,
      serial: serial,
      includeTarget: includeTarget,
    );
    final finalArgs = _buildFinalArguments(args, target, includeTarget);
    return Process.start(target.adbExecutable, finalArgs, runInShell: false);
  }

  /// Starts an ADB process whose lifetime can be cancelled and awaited.
  ///
  /// On Windows the default runner creates the process suspended inside a
  /// private Job Object and resumes it after both pipes are owned. New
  /// streaming features should use this instead of retaining a bare [Process].
  Future<OwnedCommandHandle> startOwnedProcess(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration? timeout,
    Duration terminationGrace = const Duration(seconds: 5),
    OperationContext? operation,
  }) async {
    if (args.isEmpty) {
      throw const AdbCommandException('ADB arguments must not be empty.');
    }
    final target = operation?.target ??
        _captureInvocationTarget(
          args,
          serial: serial,
          includeTarget: includeTarget,
        );
    _validateInvocationTarget(
      args,
      target,
      serial: serial,
      includeTarget: includeTarget,
    );
    final ownsOperation = operation == null;
    final context = operation ?? beginOperation(target: target);
    context.throwIfCancelled();
    final finalArgs = _buildFinalArguments(args, target, includeTarget);

    OwnedCommandHandle? handle;
    OperationResource? resource;
    try {
      handle = await _ownedProcessRunner.start(
        target.adbExecutable,
        finalArgs,
        timeout: timeout,
        terminationGrace: terminationGrace,
      );
      final ownedHandle = handle;
      resource = await context.own(cancel: () async {
        if (!ownedHandle.isCompleted) await ownedHandle.cancel();
      });
      context.throwIfCancelled();
      unawaited(_releaseCommandResource(
        ownedHandle,
        resource,
        context,
        completeOperation: ownsOperation,
      ));
      return ownedHandle;
    } catch (_) {
      if (resource != null) await resource.release();
      if (ownsOperation) await context.complete();
      rethrow;
    }
  }

  /// Starts a non-ADB executable under the same owned process boundary.
  ///
  /// A serial makes the operation device-scoped even though the executable is
  /// external (for example scrcpy or wscript). This lets a device switch stop
  /// only the process started for the old target.
  Future<OwnedCommandHandle> startOwnedExecutable(
    String executable,
    List<String> args, {
    String? serial,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
    Duration terminationGrace = const Duration(seconds: 5),
    OperationContext? operation,
  }) async {
    final normalizedExecutable = executable.trim();
    if (normalizedExecutable.isEmpty) {
      throw const AdbCommandException('Executable must not be empty.');
    }
    final target = operation?.target ??
        captureTarget(
          serial: serial,
          deviceScoped: serial != null && serial.trim().isNotEmpty,
        );
    final ownsOperation = operation == null;
    final context = operation ?? beginOperation(target: target);
    context.throwIfCancelled();

    OwnedCommandHandle? handle;
    OperationResource? resource;
    try {
      handle = await _ownedProcessRunner.start(
        normalizedExecutable,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout,
        terminationGrace: terminationGrace,
      );
      final ownedHandle = handle;
      resource = await context.own(cancel: () async {
        if (!ownedHandle.isCompleted) await ownedHandle.cancel();
      });
      context.throwIfCancelled();
      unawaited(_releaseCommandResource(
        ownedHandle,
        resource,
        context,
        completeOperation: ownsOperation,
      ));
      return ownedHandle;
    } catch (_) {
      if (resource != null) await resource.release();
      if (ownsOperation) await context.complete();
      rethrow;
    }
  }

  Future<void> _releaseCommandResource(
    OwnedCommandHandle handle,
    OperationResource resource,
    OperationContext context, {
    required bool completeOperation,
  }) async {
    try {
      await handle.done;
    } catch (_) {
      // The caller observes the primary process error through handle.done.
    } finally {
      await resource.release();
      if (completeOperation) await context.complete();
    }
  }

  Future<String> runText(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration timeout = _defaultCommandTimeout,
    OperationContext? operation,
  }) async {
    final result = await runRaw(
      args,
      serial: serial,
      includeTarget: includeTarget,
      timeout: timeout,
      operation: operation,
    );
    if (result.exitCode != 0) {
      throw AdbCommandException(
        _commandFailureMessage(result),
        exitCode: result.exitCode,
        arguments: args,
      );
    }
    return result.stdout.toString().trim();
  }

  Future<void> runSafe(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration timeout = _defaultCommandTimeout,
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    final result = await runRaw(
      args,
      serial: serial,
      includeTarget: includeTarget,
      timeout: timeout,
      onProgress: onProgress,
      operation: operation,
    );
    if (result.exitCode != 0) {
      throw AdbCommandException(
        _commandFailureMessage(result),
        exitCode: result.exitCode,
        arguments: args,
      );
    }
  }

  Future<void> execShell(String cmd) async {
    await runSafe(['shell', cmd]);
  }

  Stream<String> runStreaming(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    OperationContext? operation,
  }) async* {
    final command = await startOwnedProcess(
      args,
      serial: serial,
      includeTarget: includeTarget,
      operation: operation,
    );
    final stderrDrain = command.stderr.drain<void>();
    try {
      yield* command.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
      final exit = await command.done;
      if (exit.reason == OwnedCommandEndReason.timedOut) {
        throw AdbCommandException(
          'ADB stream timed out.',
          arguments: command.arguments,
        );
      }
      if (exit.reason == OwnedCommandEndReason.cancelled) {
        throw AdbCommandException(
          'ADB stream was cancelled.',
          arguments: command.arguments,
        );
      }
      if (exit.exitCode != 0) {
        throw AdbCommandException(
          'ADB stream exited with code ${exit.exitCode}.',
          exitCode: exit.exitCode,
          arguments: command.arguments,
        );
      }
    } finally {
      if (!command.isCompleted) {
        await command.cancel();
      }
      await stderrDrain;
    }
  }

  Future<String> runScript(
    String script, {
    String? serial,
    Duration timeout = _defaultCommandTimeout,
    OperationContext? operation,
  }) async {
    return runText(
      ['shell', script],
      serial: serial,
      timeout: timeout,
      operation: operation,
    );
  }

  DeviceTarget _captureInvocationTarget(
    List<String> args, {
    required String? serial,
    required bool includeTarget,
  }) {
    final explicitSerial = _explicitSerial(args);
    return captureTarget(
      serial: explicitSerial ?? serial,
      deviceScoped: includeTarget || explicitSerial != null,
    );
  }

  void _validateInvocationTarget(
    List<String> args,
    DeviceTarget target, {
    required String? serial,
    required bool includeTarget,
  }) {
    final explicit = _explicitSerial(args);
    final requested = explicit ?? serial?.trim();
    if (requested != null &&
        requested.isNotEmpty &&
        requested != target.serial) {
      throw ArgumentError(
        'The command serial does not match operation ${target.serial}.',
      );
    }
    if ((includeTarget || explicit != null) && !target.deviceScoped) {
      throw ArgumentError(
        'A device-scoped command cannot use a host-only operation.',
      );
    }
  }

  List<String> _buildFinalArguments(
    List<String> args,
    DeviceTarget target,
    bool includeTarget,
  ) {
    final finalArgs = <String>[...args];
    if (adbServerPort != 5037) {
      finalArgs.insertAll(0, ['-P', '$adbServerPort']);
    }
    if (includeTarget &&
        target.serial != null &&
        target.serial!.isNotEmpty &&
        _explicitSerial(finalArgs) == null) {
      finalArgs.insertAll(0, <String>['-s', target.serial!]);
    }
    return finalArgs;
  }

  String? _explicitSerial(List<String> args) {
    for (var i = 0; i < args.length - 1; i++) {
      if (args[i] == '-s') {
        final serial = args[i + 1].trim();
        return serial.isEmpty ? null : serial;
      }
    }
    return null;
  }

  List<String> _splitLegacyCommand(String command) {
    final result = <String>[];
    final current = StringBuffer();
    String? quote;
    var escaped = false;

    for (final rune in command.runes) {
      final char = String.fromCharCode(rune);
      if (escaped) {
        current.write(char);
        escaped = false;
      } else if (char == r'\' && quote == '"') {
        escaped = true;
      } else if (quote != null) {
        if (char == quote) {
          quote = null;
        } else {
          current.write(char);
        }
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (RegExp(r'\s').hasMatch(char)) {
        if (current.isNotEmpty) {
          result.add(current.toString());
          current.clear();
        }
      } else {
        current.write(char);
      }
    }
    if (escaped) current.write(r'\');
    if (quote != null) {
      throw const FormatException('Unterminated quote in ADB command.');
    }
    if (current.isNotEmpty) result.add(current.toString());
    if (result.isEmpty) {
      throw const FormatException('ADB command is empty.');
    }
    return result;
  }

  String _commandFailureMessage(ProcessResult result) {
    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    final detail = stderr.isNotEmpty ? stderr : stdout;
    return detail.isEmpty
        ? 'ADB exited with code ${result.exitCode}.'
        : 'ADB exited with code ${result.exitCode}: $detail';
  }

  // 基础功能保持不变...
  Future<Map<String, String>> getDeviceDetails() async {
    final serial = _targetSerial;
    try {
      final output = await runScript('''
        getprop ro.product.brand
        echo "---"
        getprop ro.product.model
        echo "---"
        getprop ro.build.version.release
        echo "---"
        getprop ro.build.version.sdk
      ''', serial: serial);
      final parts = output.split('---');
      if (parts.length < 4) return {};
      return {
        'brand': parts[0].trim(),
        'model': parts[1].trim(),
        'android': parts[2].trim(),
        'sdk': parts[3].trim(),
      };
    } catch (e) {
      return {};
    }
  }

  Future<String> getDeviceModel(String serial) async {
    try {
      final result =
          await runRaw(['-s', serial, 'shell', 'getprop', 'ro.product.model']);
      if (result.exitCode == 0) {
        String model = result.stdout.toString().trim();
        return model.isEmpty ? serial : model;
      }
      return serial;
    } catch (_) {
      return serial;
    }
  }

  Future<Map<String, dynamic>> getSystemStatus() async {
    final serial = _targetSerial;
    try {
      final output = await runScript('''
        uname -r
        echo "---SPLIT---"
        cat /proc/meminfo
        echo "---SPLIT---"
        df -h
        echo "---SPLIT---"
        cat /proc/stat
      ''', serial: serial);
      final parts = output.split('---SPLIT---');
      if (parts.length < 4) return {};
      return {
        'kernel': parts[0].trim(),
        'ram': _parseRam(parts[1]),
        'storage': _parseStorage(parts[2]),
        'cpu_stat': parts[3],
      };
    } catch (e) {
      return {};
    }
  }

  Future<void> reboot() async => await runSafe(['reboot']);

  Future<Map<String, String>> getAllProps() async {
    final serial = _targetSerial;
    try {
      final output = await runText(['shell', 'getprop'], serial: serial);
      final lines = output.split('\n');
      final Map<String, String> props = {};
      final regex = RegExp(r'\[(.*?)\]: \[(.*?)\]');
      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          props[match.group(1)!] = match.group(2)!;
        }
      }
      return props;
    } catch (_) {
      return {};
    }
  }

  Future<void> setProp(String key, String value) async {
    await runSafe(['shell', 'setprop', key, value]);
  }

  Future<String> dumpUi({String? serial}) async {
    final target = captureTarget(serial: serial);
    final operation = beginOperation(
      target: target,
      deadline: const Duration(minutes: 2),
    );
    final id = DateTime.now().microsecondsSinceEpoch;
    final remotePath = '/data/local/tmp/shirabox_ui_$id.xml';
    final localFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}shirabox_ui_$id.xml',
    );
    operation.deferCleanup(() async {
      try {
        if (await localFile.exists()) await localFile.delete();
      } catch (_) {}
    });
    operation.deferCleanup(
      () => _removeRemoteTempFile(remotePath, serial: target.serial),
    );
    try {
      await runSafe(
        ['shell', 'uiautomator', 'dump', remotePath],
        operation: operation,
      );
      final res = await runRaw(
        ['pull', remotePath, localFile.path],
        timeout: const Duration(minutes: 2),
        operation: operation,
      );
      operation.token.throwIfCancelled();
      if (res.exitCode == 0) {
        if (await localFile.exists()) {
          operation.token.throwIfCancelled();
          final content = await localFile.readAsString();
          operation.token.throwIfCancelled();
          return content;
        }
      }
      return "";
    } catch (_) {
      return "";
    } finally {
      await operation.complete();
    }
  }

  Future<String?> getForegroundApp() async {
    final serial = _targetSerial;
    try {
      final output = await runText(
        ['shell', 'dumpsys', 'window', 'displays'],
        serial: serial,
      );
      final regex = RegExp(r'mCurrentFocus=Window\{[^\}\s]+ ([\w\.]+)/');
      final match = regex.firstMatch(output);
      if (match != null) return match.group(1);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<File?> takeScreenshot({String? serial}) async {
    final target = captureTarget(serial: serial);
    final operation = beginOperation(
      target: target,
      deadline: const Duration(minutes: 2),
    );
    final ts = DateTime.now().microsecondsSinceEpoch;
    final remotePath = '/data/local/tmp/shirabox_screen_$ts.png';
    final localFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}shirabox_screen_$ts.png',
    );
    final localCleanup = operation.deferCleanup(() async {
      try {
        if (await localFile.exists()) await localFile.delete();
      } catch (_) {}
    });
    operation.deferCleanup(
      () => _removeRemoteTempFile(remotePath, serial: target.serial),
    );
    try {
      await runSafe(
        ['shell', 'screencap', '-p', remotePath],
        operation: operation,
      );
      final res = await runRaw(
        ['pull', remotePath, localFile.path],
        timeout: const Duration(minutes: 2),
        operation: operation,
      );
      operation.token.throwIfCancelled();
      if (res.exitCode == 0 && await localFile.exists()) {
        operation.token.throwIfCancelled();
        await localCleanup.release();
        unawaited(_deleteOldScreenshots(localFile.path));
        return localFile;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await operation.complete();
    }
  }

  Future<void> _removeRemoteTempFile(
    String remotePath, {
    required String? serial,
  }) async {
    try {
      await runSafe(
        ['shell', 'rm', '-f', '--', remotePath],
        serial: serial,
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  Future<void> _deleteOldScreenshots(String keepPath) async {
    try {
      await for (final entity in Directory.systemTemp.list()) {
        if (entity is File &&
            entity.path != keepPath &&
            entity.uri.pathSegments.last.startsWith('shirabox_screen_')) {
          try {
            final age = DateTime.now().difference(await entity.lastModified());
            if (age > const Duration(hours: 1)) await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> rebootBootloader() async =>
      await runSafe(['reboot', 'bootloader']);
  Future<void> rebootRecovery() async => await runSafe(['reboot', 'recovery']);
  Future<void> shutdown() async => await runSafe(['shell', 'reboot', '-p']);

  Future<String> connect(String ipPort) async {
    try {
      if (!isValid && !await checkAvailability()) {
        throw const AdbCommandException('No working ADB executable found.');
      }
      await ensureServerStarted();
      return await runText(['connect', ipPort], includeTarget: false);
    } catch (e) {
      return 'ERROR: $e';
    }
  }

  Future<String> disconnect(String ipPort) async {
    try {
      return await runText(['disconnect', ipPort], includeTarget: false);
    } catch (e) {
      return 'ERROR: $e';
    }
  }

  Map<String, dynamic> _parseRam(String raw) {
    try {
      final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(raw);
      final availMatch = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(raw);
      if (totalMatch != null && availMatch != null) {
        double total = double.parse(totalMatch.group(1)!) / 1024 / 1024;
        double avail = double.parse(availMatch.group(1)!) / 1024 / 1024;
        double used = total - avail;
        return {
          'ratio': used / total,
          'text': "${used.toStringAsFixed(1)}GB / ${total.toStringAsFixed(1)}GB"
        };
      }
    } catch (_) {}
    return {'ratio': 0.0, 'text': "- / -"};
  }

  Map<String, dynamic> _parseStorage(String raw) {
    try {
      final lines = raw.split('\n');
      for (var line in lines) {
        if (line.trim().endsWith('/data')) {
          final parts =
              line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
          if (parts.length >= 5) {
            String size = parts[parts.length - 5];
            String used = parts[parts.length - 4];
            String usePerStr = parts[parts.length - 2].replaceAll('%', '');
            double ratio = (double.tryParse(usePerStr) ?? 0) / 100.0;
            return {'ratio': ratio, 'text': "$used / $size"};
          }
        }
      }
    } catch (_) {}
    return {'ratio': 0.0, 'text': "- / -"};
  }
}

class AdbCommandException implements Exception {
  final String message;
  final int? exitCode;
  final List<String> arguments;

  const AdbCommandException(
    this.message, {
    this.exitCode,
    this.arguments = const [],
  });

  @override
  String toString() => message;
}

/// Stateful parser for the `[ 42%]` progress records emitted by modern ADB.
/// It tolerates records split across arbitrary stdout/stderr chunks and only
/// emits monotonic values suitable for a progress indicator.
class AdbProgressParser {
  String _tail = '';
  double _lastValue = -1;

  double get lastValue => _lastValue;

  List<double> addBytes(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    final decoded = ascii.decode(bytes, allowInvalid: true);
    final text = '$_tail$decoded';
    final values = <double>[];
    for (final match in RegExp(r'\[\s*(\d{1,3})%\]').allMatches(text)) {
      final percent = int.tryParse(match.group(1)!);
      if (percent == null) continue;
      final value = percent.clamp(0, 100) / 100.0;
      if (value > _lastValue) {
        _lastValue = value;
        values.add(value);
      }
    }
    _tail = text.length > 64 ? text.substring(text.length - 64) : text;
    return values;
  }
}
