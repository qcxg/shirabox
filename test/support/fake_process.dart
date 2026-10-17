import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:shirabox/services/owned_process.dart';

class ProcessLaunchRecord {
  const ProcessLaunchRecord({
    required this.executable,
    required this.arguments,
    this.workingDirectory,
    this.environment,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;
}

class FakeProcessLauncher implements ProcessLauncher {
  final Queue<Future<Process>> _queued = Queue<Future<Process>>();
  final List<ProcessLaunchRecord> launches = <ProcessLaunchRecord>[];

  void enqueue(FakeProcess process) =>
      _queued.add(Future<Process>.value(process));

  void enqueueFuture(Future<Process> process) => _queued.add(process);

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    launches.add(ProcessLaunchRecord(
      executable: executable,
      arguments: List<String>.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      environment: environment == null
          ? null
          : Map<String, String>.unmodifiable(environment),
    ));
    if (_queued.isEmpty) {
      throw StateError('No fake process was queued.');
    }
    return _queued.removeFirst();
  }
}

class FakeProcess implements Process {
  FakeProcess({
    required this.pid,
    this.killExitCode = -1,
    this.completeOnKill = true,
  }) : _stdin = IOSink(_DiscardingByteConsumer());

  @override
  final int pid;
  final int killExitCode;
  final bool completeOnKill;

  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>(sync: true);
  final StreamController<List<int>> _stderrController =
      StreamController<List<int>>(sync: true);
  final Completer<int> _exitCompleter = Completer<int>();
  final IOSink _stdin;
  int killCalls = 0;
  bool _streamsClosed = false;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  void addStdout(String value) => addStdoutBytes(utf8.encode(value));

  void addStdoutBytes(List<int> value) {
    if (!_streamsClosed) _stdoutController.add(List<int>.of(value));
  }

  void addStderr(String value) => addStderrBytes(utf8.encode(value));

  void addStderrBytes(List<int> value) {
    if (!_streamsClosed) _stderrController.add(List<int>.of(value));
  }

  Future<void> complete(int code) async {
    if (_exitCompleter.isCompleted) return;
    _streamsClosed = true;
    await Future.wait<void>([
      _stdoutController.close(),
      _stderrController.close(),
    ]);
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    if (_exitCompleter.isCompleted) return false;
    if (completeOnKill) unawaited(complete(killExitCode));
    return true;
  }
}

class FakeProcessJobController implements ProcessJobController {
  int _nextToken = 1;
  final List<int> attachedPids = <int>[];
  final List<(int, int)> terminated = <(int, int)>[];
  final List<int> released = <int>[];
  final Map<int, int> tokenToPid = <int, int>{};
  Object? attachError;
  Object? terminateError;
  Object? releaseError;
  FutureOr<void> Function(int token, int exitCode)? onTerminate;

  @override
  Future<int?> attach(int pid) async {
    final error = attachError;
    if (error != null) throw error;
    attachedPids.add(pid);
    final token = _nextToken++;
    tokenToPid[token] = pid;
    return token;
  }

  @override
  Future<void> terminate(int token, {required int exitCode}) async {
    terminated.add((token, exitCode));
    final error = terminateError;
    if (error != null) throw error;
    await onTerminate?.call(token, exitCode);
  }

  @override
  Future<void> release(int token) async {
    released.add(token);
    final error = releaseError;
    if (error != null) throw error;
    tokenToPid.remove(token);
  }
}

class _DiscardingByteConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}
