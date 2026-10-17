import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/operation_context.dart';
import 'package:shirabox/services/agent_client.dart';
import 'package:shirabox/services/owned_process.dart';

import 'support/fake_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const stagingChannel = MethodChannel('shirabox/native_staging');
  final stagingDirectories = <String>[];

  setUp(() {
    stagingDirectories.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(stagingChannel, (call) async {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      if (call.method == 'createAdbStagingDirectory') {
        final directory = await Directory.systemTemp.createTemp(
          arguments['prefix']! as String,
        );
        stagingDirectories.add(directory.path);
        return directory.path;
      }
      if (call.method == 'deleteAdbStagingDirectory') {
        final directory = Directory(arguments['path']! as String);
        if (await directory.exists()) {
          await directory.delete(
            recursive: arguments['recursive']! as bool,
          );
        }
        return null;
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(stagingChannel, null);
    for (final path in stagingDirectories) {
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  test('stop waits for and removes a forward acquired after closure', () async {
    final adb = _LifecycleAdb(blockForward: true);
    final client = AgentClient(adb);
    addTearDown(client.stop);

    final startup = client.ensureAgentRunning(serial: 'device-a');
    final startupExpectation = expectLater(
      startup,
      throwsA(isA<AdbCommandException>()),
    );
    await adb.forwardRequested.future.timeout(const Duration(seconds: 5));

    final stopped = client.stop();
    adb.releaseForward();

    await stopped.timeout(const Duration(seconds: 10));
    await startupExpectation;
    expect(adb.forwardWasRemoved, isTrue);
    await expectLater(
      client.ensureAgentRunning(serial: 'device-a'),
      throwsA(isA<AdbCommandException>()),
    );
  });

  test('late helper push is killed and followed by ordered cleanup', () async {
    final adb = _LifecycleAdb();
    final client = AgentClient(adb);
    addTearDown(client.stop);

    final startup = client.ensureAgentRunning(serial: 'device-b');
    final startupExpectation = expectLater(
      startup,
      throwsA(isA<AdbCommandException>()),
    );
    await adb.pushRequested.future.timeout(const Duration(seconds: 20));

    final stopped = client.stop();
    await adb.firstJarRemoval.future.timeout(const Duration(seconds: 5));

    final process = await _startBlockingProcess();
    addTearDown(() {
      process.kill();
    });
    adb.completePush(process);

    await stopped.timeout(const Duration(seconds: 15));
    await startupExpectation;
    await process.exitCode.timeout(const Duration(seconds: 5));
    expect(adb.jarRemovalCount, greaterThanOrEqualTo(2));
    expect(adb.forwardWasRemoved, isTrue);
  });
}

Future<Process> _startBlockingProcess() {
  if (Platform.isWindows) {
    return Process.start(
      r'C:\Windows\System32\PING.EXE',
      const ['-n', '30', '127.0.0.1'],
      runInShell: false,
    );
  }
  return Process.start('sleep', const ['30'], runInShell: false);
}

class _LifecycleAdb extends AdbCore {
  _LifecycleAdb({this.blockForward = false}) : super(checkOnCreate: false) {
    _ownedRunner = OwnedProcessRunner(
      launcher: _LifecycleProcessLauncher(this),
      jobController: _jobs,
    );
  }

  final bool blockForward;
  final Completer<void> forwardRequested = Completer<void>();
  final Completer<void> pushRequested = Completer<void>();
  final Completer<void> firstJarRemoval = Completer<void>();
  final Completer<void> _forwardRelease = Completer<void>();
  final Completer<Process> _pushProcess = Completer<Process>();
  final FakeProcessJobController _jobs = FakeProcessJobController();
  late final OwnedProcessRunner _ownedRunner;
  final List<List<String>> calls = [];
  int jarRemovalCount = 0;

  bool get forwardWasRemoved => calls.any(
        (args) =>
            args.length >= 3 && args[0] == 'forward' && args[1] == '--remove',
      );

  void releaseForward() {
    if (!_forwardRelease.isCompleted) _forwardRelease.complete();
  }

  void completePush(Process process) {
    if (!_pushProcess.isCompleted) _pushProcess.complete(process);
    _jobs.onTerminate = (_, __) => process.kill();
  }

  @override
  Future<void> runSafe(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration timeout = const Duration(seconds: 30),
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    calls.add(List<String>.of(args));
    if (args.length >= 2 && args[0] == 'forward' && args[1] == '--no-rebind') {
      if (!forwardRequested.isCompleted) forwardRequested.complete();
      if (blockForward) await _forwardRelease.future;
      return;
    }
    if (args.length >= 5 &&
        args[0] == 'shell' &&
        args[1] == 'rm' &&
        args.last == '/data/local/tmp/server.jar') {
      jarRemovalCount++;
      if (!firstJarRemoval.isCompleted) firstJarRemoval.complete();
    }
  }

  @override
  Future<OwnedCommandHandle> startOwnedProcess(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration? timeout,
    Duration terminationGrace = const Duration(seconds: 5),
    OperationContext? operation,
  }) {
    if (args.isNotEmpty && args.first == 'push') {
      if (!pushRequested.isCompleted) pushRequested.complete();
      final finalArgs = <String>[
        if (includeTarget && serial != null) ...['-s', serial],
        ...args,
      ];
      return _ownedRunner.start(
        executablePath,
        finalArgs,
        timeout: timeout,
        terminationGrace: terminationGrace,
      );
    }
    throw StateError('The launcher must not start during this lifecycle test.');
  }
}

class _LifecycleProcessLauncher implements ProcessLauncher {
  _LifecycleProcessLauncher(this.owner);

  final _LifecycleAdb owner;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    if (arguments.contains('push')) return owner._pushProcess.future;
    throw StateError('The launcher must not start during this lifecycle test.');
  }
}
