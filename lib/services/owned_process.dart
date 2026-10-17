import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

enum OwnedCommandEndReason { exited, cancelled, timedOut }

class OwnedCommandExit {
  const OwnedCommandExit({
    required this.exitCode,
    required this.reason,
    required this.duration,
    required this.treeOwned,
    this.terminationError,
    this.releaseError,
  });

  final int exitCode;
  final OwnedCommandEndReason reason;
  final Duration duration;
  final bool treeOwned;
  final Object? terminationError;
  final Object? releaseError;

  bool get wasCancelled => reason == OwnedCommandEndReason.cancelled;
  bool get timedOut => reason == OwnedCommandEndReason.timedOut;
}

class OwnedProcessException implements Exception {
  const OwnedProcessException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

abstract interface class ProcessLauncher {
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

class IoProcessLauncher implements ProcessLauncher {
  const IoProcessLauncher();

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
  }
}

abstract interface class _AtomicallyOwnedProcess implements Process {
  int get ownershipToken;
  Future<void> resumeOwned();
}

/// Windows launcher backed by the native runner.
///
/// The child is returned while still suspended and already belongs to its
/// private Job Object. [OwnedProcessRunner] subscribes to both pipes before it
/// calls [resumeOwned], so even an immediate output flood has a bounded owner.
class NativeProcessLauncher implements ProcessLauncher {
  NativeProcessLauncher({
    MethodChannel? channel,
    EventChannel? eventChannel,
  }) : _bridge = _NativeProcessBridge(
          channel: channel,
          eventChannel: eventChannel,
        );

  final _NativeProcessBridge _bridge;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return _bridge.startSuspended(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }
}

class _NativeProcessBridge {
  _NativeProcessBridge({
    MethodChannel? channel,
    EventChannel? eventChannel,
  })  : _channel = channel ?? _defaultChannel,
        _eventChannel = eventChannel ?? _defaultEventChannel;

  static const MethodChannel _defaultChannel =
      MethodChannel('shirabox/process_job');
  static const EventChannel _defaultEventChannel =
      EventChannel('shirabox/process_events');

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final Map<int, _NativeOwnedProcess> _processes = <int, _NativeOwnedProcess>{};
  StreamSubscription<Object?>? _eventSubscription;
  Future<void>? _readyFuture;

  Future<void> _ensureReady() => _readyFuture ??= _waitForEventSink();

  Future<void> _waitForEventSink() async {
    _eventSubscription ??= _eventChannel.receiveBroadcastStream().listen(
          _handleEvent,
          onError: _handleEventError,
          onDone: _handleEventDone,
        );

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      try {
        final ready = await _channel.invokeMethod<bool>(
          'processEventsReady',
          const <String, Object?>{},
        );
        if (ready == true) return;
      } on MissingPluginException catch (error) {
        throw OwnedProcessException(
          'Atomic Windows process launch is unavailable in this runner.',
          cause: error,
        );
      } on PlatformException catch (error) {
        throw OwnedProcessException(
          'Unable to initialize the native process event stream.',
          cause: error,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const OwnedProcessException(
          'The native process event stream did not become ready.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<_NativeOwnedProcess> startSuspended(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    await _ensureReady();
    final callArguments = <String, Object?>{
      'executable': executable,
      'arguments': List<String>.of(arguments, growable: false),
    };
    if (workingDirectory != null) {
      callArguments['workingDirectory'] = workingDirectory;
    }
    if (environment != null) {
      callArguments['environment'] = <String, String>{
        ...Platform.environment,
        ...environment,
      };
    }

    Map<Object?, Object?>? response;
    try {
      response = await _channel.invokeMapMethod<Object?, Object?>(
        'launchOwnedProcess',
        callArguments,
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to create the atomic Windows process.',
        cause: error,
      );
    }
    final token = response?['token'];
    final pid = response?['pid'];
    if (token is! int || token <= 0 || pid is! int || pid <= 0) {
      throw const OwnedProcessException(
        'Native process launch returned invalid ownership metadata.',
      );
    }

    final process = _NativeOwnedProcess(
      bridge: this,
      ownershipToken: token,
      pid: pid,
    );
    _processes[token] = process;
    return process;
  }

  Future<void> resume(int token) async {
    try {
      await _channel.invokeMethod<void>(
        'resumeOwnedProcess',
        <String, Object?>{'token': token},
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to resume the atomic Windows process.',
        cause: error,
      );
    }
  }

  Future<void> writeStdin(int token, List<int> bytes) async {
    if (bytes.isEmpty) return;
    try {
      await _channel.invokeMethod<void>(
        'writeProcessStdin',
        <String, Object?>{
          'token': token,
          'data': Uint8List.fromList(bytes),
        },
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to write to the owned process stdin.',
        cause: error,
      );
    }
  }

  Future<void> closeStdin(int token) async {
    try {
      await _channel.invokeMethod<void>(
        'closeProcessStdin',
        <String, Object?>{'token': token},
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to close the owned process stdin.',
        cause: error,
      );
    }
  }

  Future<void> terminate(int token, int exitCode) async {
    try {
      await _channel.invokeMethod<void>(
        'terminateProcessJob',
        <String, Object?>{'token': token, 'exitCode': exitCode},
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to terminate the atomic Windows process.',
        cause: error,
      );
    }
  }

  void _handleEvent(Object? event) {
    if (event is! Map<Object?, Object?>) return;
    final token = event['token'];
    if (token is! int) return;
    final process = _processes[token];
    if (process == null) return;
    process.handleEvent(event);
    if (event['type'] == 'exit') _processes.remove(token);
  }

  void _handleEventError(Object error, StackTrace stackTrace) {
    final failure = OwnedProcessException(
      'The native process event stream failed.',
      cause: error,
    );
    final processes = _processes.values.toList(growable: false);
    _processes.clear();
    for (final process in processes) {
      process.fail(failure, stackTrace);
    }
  }

  void _handleEventDone() {
    final error = const OwnedProcessException(
      'The native process event stream closed unexpectedly.',
    );
    final processes = _processes.values.toList(growable: false);
    _processes.clear();
    for (final process in processes) {
      process.fail(error, StackTrace.current);
    }
  }
}

class _NativeOwnedProcess implements _AtomicallyOwnedProcess {
  _NativeOwnedProcess({
    required _NativeProcessBridge bridge,
    required this.ownershipToken,
    required this.pid,
  }) : _bridge = bridge {
    _stdin = IOSink(_NativeStdinConsumer(bridge, ownershipToken));
  }

  final _NativeProcessBridge _bridge;
  @override
  final int ownershipToken;
  @override
  final int pid;
  final StreamController<List<int>> _stdout =
      StreamController<List<int>>(sync: true);
  final StreamController<List<int>> _stderr =
      StreamController<List<int>>(sync: true);
  final Completer<int> _exitCode = Completer<int>();
  late final IOSink _stdin;
  bool _stdoutClosed = false;
  bool _stderrClosed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _stdin;
  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> resumeOwned() => _bridge.resume(ownershipToken);

  void handleEvent(Map<Object?, Object?> event) {
    switch (event['type']) {
      case 'stdout':
        final data = event['data'];
        if (!_stdoutClosed && data is Uint8List) _stdout.add(data);
        break;
      case 'stderr':
        final data = event['data'];
        if (!_stderrClosed && data is Uint8List) _stderr.add(data);
        break;
      case 'stdoutClosed':
        _closeStdout();
        break;
      case 'stderrClosed':
        _closeStderr();
        break;
      case 'streamError':
        final stream = event['stream'];
        final error = OwnedProcessException(
          'Native $stream pipe failed with Windows error '
          '${event['windowsError']}.',
        );
        if (stream == 'stderr') {
          if (!_stderrClosed) _stderr.addError(error);
        } else if (!_stdoutClosed) {
          _stdout.addError(error);
        }
        break;
      case 'exit':
        _closeStdout();
        _closeStderr();
        final code = event['exitCode'];
        if (!_exitCode.isCompleted) {
          if (code is int) {
            _exitCode.complete(code);
          } else {
            _exitCode.completeError(const OwnedProcessException(
              'Native process exit event did not contain an exit code.',
            ));
          }
        }
        break;
    }
  }

  void fail(Object error, StackTrace stackTrace) {
    if (!_stdoutClosed) _stdout.addError(error, stackTrace);
    if (!_stderrClosed) _stderr.addError(error, stackTrace);
    _closeStdout();
    _closeStderr();
    if (!_exitCode.isCompleted) _exitCode.completeError(error, stackTrace);
  }

  void _closeStdout() {
    if (_stdoutClosed) return;
    _stdoutClosed = true;
    unawaited(_stdout.close());
  }

  void _closeStderr() {
    if (_stderrClosed) return;
    _stderrClosed = true;
    unawaited(_stderr.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_exitCode.isCompleted) return false;
    unawaited(
      _bridge.terminate(ownershipToken, 0x53484258).catchError((_) {}),
    );
    return true;
  }
}

class _NativeStdinConsumer implements StreamConsumer<List<int>> {
  _NativeStdinConsumer(this._bridge, this._token);

  final _NativeProcessBridge _bridge;
  final int _token;
  bool _closed = false;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (_closed) throw StateError('The process stdin is closed.');
    await for (final chunk in stream) {
      await _bridge.writeStdin(_token, chunk);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _bridge.closeStdin(_token);
  }
}

abstract interface class ProcessJobController {
  /// Returns a native ownership token, or null on platforms without process
  /// tree support.
  Future<int?> attach(int pid);

  Future<void> terminate(int token, {required int exitCode});

  Future<void> release(int token);
}

class NativeProcessJobController implements ProcessJobController {
  NativeProcessJobController({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  static const MethodChannel _defaultChannel =
      MethodChannel('shirabox/process_job');

  final MethodChannel _channel;

  @override
  Future<int?> attach(int pid) async {
    if (!Platform.isWindows) return null;
    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'attachProcess',
        <String, Object?>{'pid': pid},
      );
      final token = response?['token'];
      if (token is int && token > 0) return token;
      throw const OwnedProcessException(
        'Native process ownership returned an invalid token.',
      );
    } on MissingPluginException catch (error) {
      throw OwnedProcessException(
        'Windows process ownership is unavailable in this runner.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to attach the process to a Windows Job Object.',
        cause: error,
      );
    }
  }

  @override
  Future<void> terminate(int token, {required int exitCode}) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>(
        'terminateProcessJob',
        <String, Object?>{'token': token, 'exitCode': exitCode},
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to terminate the Windows process job.',
        cause: error,
      );
    }
  }

  @override
  Future<void> release(int token) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>(
        'releaseProcessJob',
        <String, Object?>{'token': token},
      );
    } on PlatformException catch (error) {
      throw OwnedProcessException(
        'Unable to release the Windows process job.',
        cause: error,
      );
    }
  }
}

class NoopProcessJobController implements ProcessJobController {
  const NoopProcessJobController();

  @override
  Future<int?> attach(int pid) async => null;

  @override
  Future<void> release(int token) async {}

  @override
  Future<void> terminate(int token, {required int exitCode}) async {}
}

class OwnedProcessRunner {
  OwnedProcessRunner({
    ProcessLauncher? launcher,
    ProcessJobController? jobController,
  })  : _launcher = launcher ??
            (Platform.isWindows
                ? NativeProcessLauncher()
                : const IoProcessLauncher()),
        _jobController = jobController ?? NativeProcessJobController();

  final ProcessLauncher _launcher;
  final ProcessJobController _jobController;

  Future<OwnedCommandHandle> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
    Duration terminationGrace = const Duration(seconds: 5),
  }) async {
    final immutableArguments = List<String>.unmodifiable(arguments);
    final process = await _launcher.start(
      executable,
      immutableArguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    // Own both pipes before an atomic native child is resumed (or before a
    // fallback child is attached). This prevents a noisy process from filling
    // a pipe while no feature listener exists and keeps late starts safe.
    final stdoutRelay = _OwnedOutputRelay(process.stdout);
    final stderrRelay = _OwnedOutputRelay(process.stderr);

    int? jobToken;
    try {
      if (process is _AtomicallyOwnedProcess) {
        jobToken = process.ownershipToken;
        await process.resumeOwned();
      } else {
        jobToken = await _jobController.attach(process.pid);
      }
    } catch (error) {
      if (jobToken != null) {
        try {
          await _jobController.terminate(
            jobToken,
            exitCode: OwnedCommandHandle._cancelExitCode,
          );
        } catch (_) {
          process.kill();
        }
      } else {
        process.kill();
      }
      try {
        await process.exitCode.timeout(terminationGrace);
      } catch (_) {}
      if (jobToken != null) {
        try {
          await _jobController.release(jobToken);
        } catch (_) {}
      }
      throw OwnedProcessException(
        'The process could not enter its owned running state.',
        cause: error,
      );
    }

    return OwnedCommandHandle._(
      process: process,
      stdoutRelay: stdoutRelay,
      stderrRelay: stderrRelay,
      executable: executable,
      arguments: immutableArguments,
      jobController: _jobController,
      jobToken: jobToken,
      timeout: timeout,
      terminationGrace: terminationGrace,
    );
  }
}

class OwnedCommandCapture {
  const OwnedCommandCapture({
    required this.bytes,
    required this.observedBytes,
    required this.truncated,
  });

  final Uint8List bytes;
  final int observedBytes;
  final bool truncated;

  int get capturedBytes => bytes.length;

  String decodeUtf8({bool allowMalformed = true}) =>
      utf8.decode(bytes, allowMalformed: allowMalformed);
}

class OwnedCommandResult {
  const OwnedCommandResult({
    required this.pid,
    required this.executable,
    required this.arguments,
    required this.exit,
    required this.stdout,
    required this.stderr,
  });

  final int pid;
  final String executable;
  final List<String> arguments;
  final OwnedCommandExit exit;
  final OwnedCommandCapture stdout;
  final OwnedCommandCapture stderr;
}

class OwnedCommandHandle {
  OwnedCommandHandle._({
    required Process process,
    required _OwnedOutputRelay stdoutRelay,
    required _OwnedOutputRelay stderrRelay,
    required this.executable,
    required this.arguments,
    required ProcessJobController jobController,
    required int? jobToken,
    required Duration? timeout,
    required Duration terminationGrace,
  })  : _process = process,
        _stdoutRelay = stdoutRelay,
        _stderrRelay = stderrRelay,
        _jobController = jobController,
        _jobToken = jobToken,
        _terminationGrace = terminationGrace,
        startedAt = DateTime.now() {
    _process.exitCode.then(_completeFromExit, onError: _completeFromExitError);
    if (timeout != null) {
      _timeoutTimer = Timer(timeout, () {
        unawaited(_requestTermination(OwnedCommandEndReason.timedOut));
      });
    }
  }

  static const int _cancelExitCode = 0x53484258;
  static const int _timeoutExitCode = 0x53484254;

  final Process _process;
  final _OwnedOutputRelay _stdoutRelay;
  final _OwnedOutputRelay _stderrRelay;
  final ProcessJobController _jobController;
  final int? _jobToken;
  final Duration _terminationGrace;
  final Completer<OwnedCommandExit> _completion = Completer<OwnedCommandExit>();

  final String executable;
  final List<String> arguments;
  final DateTime startedAt;

  Timer? _timeoutTimer;
  OwnedCommandEndReason? _requestedReason;
  Future<void>? _terminationInFlight;
  Object? _terminationError;

  int get pid => _process.pid;
  Stream<List<int>> get stdout => _stdoutRelay.stream;
  Stream<List<int>> get stderr => _stderrRelay.stream;
  IOSink get stdin => _process.stdin;
  bool get treeOwned => _jobToken != null;
  bool get isCompleted => _completion.isCompleted;
  Future<OwnedCommandExit> get done => _completion.future;
  Future<void> get stdoutDone => _stdoutRelay.done;
  Future<void> get stderrDone => _stderrRelay.done;

  Future<OwnedCommandResult> collect({
    int maxBytesPerStream = 16 * 1024 * 1024,
    void Function(List<int> bytes)? onStdoutChunk,
    void Function(List<int> bytes)? onStderrChunk,
  }) async {
    if (maxBytesPerStream < 0) {
      throw ArgumentError.value(
        maxBytesPerStream,
        'maxBytesPerStream',
        'must not be negative',
      );
    }
    final stdoutFuture = _captureOwnedOutput(
      stdout,
      maxBytes: maxBytesPerStream,
      onChunk: onStdoutChunk,
    );
    final stderrFuture = _captureOwnedOutput(
      stderr,
      maxBytes: maxBytesPerStream,
      onChunk: onStderrChunk,
    );
    final exit = await done;
    final captures = await Future.wait<OwnedCommandCapture>(
      <Future<OwnedCommandCapture>>[stdoutFuture, stderrFuture],
    );
    return OwnedCommandResult(
      pid: pid,
      executable: executable,
      arguments: arguments,
      exit: exit,
      stdout: captures[0],
      stderr: captures[1],
    );
  }

  Future<OwnedCommandExit> cancel() async {
    await _requestTermination(OwnedCommandEndReason.cancelled);
    try {
      final exit = await done.timeout(_terminationGrace);
      final cleanupError = exit.terminationError ?? exit.releaseError;
      if (cleanupError != null) {
        throw OwnedProcessException(
          'The process exited, but process-tree cleanup was not confirmed.',
          cause: cleanupError,
        );
      }
      return exit;
    } on TimeoutException catch (error) {
      throw OwnedProcessException(
        'The owned process did not exit within '
        '${_terminationGrace.inMilliseconds} ms after cancellation.',
        cause: error,
      );
    }
  }

  Future<void> _requestTermination(OwnedCommandEndReason reason) {
    if (_completion.isCompleted) return Future<void>.value();
    _requestedReason ??= reason;
    return _terminationInFlight ??= _terminate(reason);
  }

  Future<void> _terminate(OwnedCommandEndReason reason) async {
    _timeoutTimer?.cancel();
    try {
      await _process.stdin.close();
    } catch (_) {}

    final token = _jobToken;
    try {
      if (token != null) {
        await _jobController.terminate(
          token,
          exitCode: reason == OwnedCommandEndReason.timedOut
              ? _timeoutExitCode
              : _cancelExitCode,
        );
      } else {
        _process.kill();
      }
    } catch (error) {
      _terminationError = error;
      _process.kill();
    }
  }

  Future<void> _completeFromExit(int exitCode) async {
    if (_completion.isCompleted) return;
    _timeoutTimer?.cancel();
    Object? releaseError;
    final token = _jobToken;
    if (token != null) {
      try {
        await _jobController.release(token);
      } catch (error) {
        releaseError = error;
      }
    }
    if (_completion.isCompleted) return;
    _completion.complete(OwnedCommandExit(
      exitCode: exitCode,
      reason: _requestedReason ?? OwnedCommandEndReason.exited,
      duration: DateTime.now().difference(startedAt),
      treeOwned: token != null,
      terminationError: _terminationError,
      releaseError: releaseError,
    ));
  }

  void _completeFromExitError(Object error, StackTrace stackTrace) {
    unawaited(_releaseAfterExitError(error, stackTrace));
  }

  Future<void> _releaseAfterExitError(
    Object error,
    StackTrace stackTrace,
  ) async {
    _timeoutTimer?.cancel();
    final token = _jobToken;
    if (token != null) {
      try {
        await _jobController.release(token);
      } catch (_) {
        // Preserve the process-observation error as the primary failure. The
        // native runner still closes every remaining job during shutdown.
      }
    }
    if (!_completion.isCompleted) {
      _completion.completeError(
        OwnedProcessException(
          'Unable to observe the owned process exit.',
          cause: error,
        ),
        stackTrace,
      );
    }
  }
}

Future<OwnedCommandCapture> _captureOwnedOutput(
  Stream<List<int>> stream, {
  required int maxBytes,
  void Function(List<int> bytes)? onChunk,
}) async {
  final bytes = BytesBuilder(copy: false);
  var observed = 0;
  var captured = 0;
  var truncated = false;
  await for (final chunk in stream) {
    onChunk?.call(chunk);
    observed += chunk.length;
    final remaining = maxBytes - captured;
    if (remaining <= 0) {
      if (chunk.isNotEmpty) truncated = true;
      continue;
    }
    if (chunk.length <= remaining) {
      bytes.add(chunk);
      captured += chunk.length;
    } else {
      bytes.add(chunk.sublist(0, remaining));
      captured += remaining;
      truncated = true;
    }
  }
  return OwnedCommandCapture(
    bytes: bytes.takeBytes(),
    observedBytes: observed,
    truncated: truncated,
  );
}

class _OwnedOutputRelay {
  _OwnedOutputRelay(Stream<List<int>> source) {
    _controller = StreamController<List<int>>(
      sync: true,
      onListen: _onListen,
      onCancel: _onCancel,
    );
    source.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  static const int _maxPrelistenBytes = 1024 * 1024;
  final Queue<List<int>> _prelistenChunks = ListQueue<List<int>>();
  late final StreamController<List<int>> _controller;
  int _prelistenBytes = 0;
  bool _hasListener = false;
  bool _listenerCancelled = false;
  bool _sourceDone = false;
  Object? _pendingError;
  StackTrace? _pendingStackTrace;
  final Completer<void> _done = Completer<void>();

  Stream<List<int>> get stream => _controller.stream;
  Future<void> get done => _done.future;

  void _onData(List<int> chunk) {
    if (_listenerCancelled || chunk.isEmpty) return;
    if (_hasListener) {
      _controller.add(chunk);
      return;
    }

    final copy = List<int>.of(chunk, growable: false);
    _prelistenChunks.add(copy);
    _prelistenBytes += copy.length;
    while (
        _prelistenBytes > _maxPrelistenBytes && _prelistenChunks.isNotEmpty) {
      _prelistenBytes -= _prelistenChunks.removeFirst().length;
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (_listenerCancelled) return;
    if (_hasListener) {
      _controller.addError(error, stackTrace);
    } else {
      _pendingError ??= error;
      _pendingStackTrace ??= stackTrace;
    }
  }

  void _onDone() {
    _sourceDone = true;
    if (!_done.isCompleted) _done.complete();
    if (_hasListener && !_listenerCancelled) {
      unawaited(_controller.close());
    }
  }

  void _onListen() {
    _hasListener = true;
    for (final chunk in _prelistenChunks) {
      _controller.add(chunk);
    }
    _prelistenChunks.clear();
    _prelistenBytes = 0;
    final error = _pendingError;
    if (error != null) {
      _controller.addError(error, _pendingStackTrace);
      _pendingError = null;
      _pendingStackTrace = null;
    }
    if (_sourceDone) unawaited(_controller.close());
  }

  Future<void> _onCancel() async {
    _listenerCancelled = true;
    _prelistenChunks.clear();
    _prelistenBytes = 0;
    // Keep the source subscription alive and discarding so neither OS pipe can
    // block process exit after a feature consumer cancels its view stream.
  }
}
