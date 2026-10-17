import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/providers/file_transfer_provider.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_file.dart';
import 'package:shirabox/services/operation_context.dart';
import 'package:shirabox/services/owned_process.dart';

import 'support/fake_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('records exact argv, streams both pipes, and releases ownership',
      () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 101);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    final runner = OwnedProcessRunner(launcher: launcher, jobController: jobs);

    final handle = await runner.start('fake-adb', const <String>[
      '-s',
      'device-a',
      'logcat',
    ]);
    final stdout = handle.stdout.transform(utf8.decoder).join();
    final stderr = handle.stderr.transform(utf8.decoder).join();
    process.addStdoutBytes(const <int>[111, 107]);
    process.addStderr('warning');
    await process.complete(0);

    final exit = await handle.done;
    expect(launcher.launches.single.executable, 'fake-adb');
    expect(
      launcher.launches.single.arguments,
      const <String>['-s', 'device-a', 'logcat'],
    );
    expect(await stdout, 'ok');
    expect(await stderr, 'warning');
    expect(jobs.attachedPids, <int>[101]);
    expect(jobs.released, <int>[1]);
    expect(exit.reason, OwnedCommandEndReason.exited);
    expect(exit.exitCode, 0);
    expect(exit.treeOwned, isTrue);
  });

  test('bounded collector reports observed and retained bytes', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 107);
    launcher.enqueue(process);
    final handle = await OwnedProcessRunner(
      launcher: launcher,
      jobController: FakeProcessJobController(),
    ).start('fake-adb', const <String>['flood']);

    final resultFuture = handle.collect(maxBytesPerStream: 4);
    process.addStdoutBytes(const <int>[1, 2, 3, 4, 5, 6]);
    process.addStderr('err');
    await process.complete(0);
    final result = await resultFuture;

    expect(result.pid, 107);
    expect(result.stdout.bytes, const <int>[1, 2, 3, 4]);
    expect(result.stdout.capturedBytes, 4);
    expect(result.stdout.observedBytes, 6);
    expect(result.stdout.truncated, isTrue);
    expect(result.stderr.decodeUtf8(), 'err');
    expect(result.stderr.truncated, isFalse);
  });

  test('AdbCore runRaw uses the owned runner and preserves progress', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 108);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    );
    final progress = <double>[];

    final resultFuture = core.runRaw(
      const <String>['push', 'source', 'destination'],
      includeTarget: false,
      onProgress: progress.add,
    );
    process.addStdout('[ 42%] source');
    process.addStderr('diagnostic');
    await process.complete(0);
    final result = await resultFuture;

    expect(result.pid, 108);
    expect(result.exitCode, 0);
    expect(result.stdout, '[ 42%] source');
    expect(result.stderr, 'diagnostic');
    expect(progress, <double>[0.42, 1]);
    expect(jobs.attachedPids, <int>[108]);
    expect(jobs.released, <int>[1]);
  });

  test('AdbCore runStreaming cancels its owned process with the listener',
      () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 109);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) => process.complete(exitCode);
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    );
    final firstLine = Completer<String>();

    final subscription = core.runStreaming(const <String>['logcat']).listen(
        (line) => firstLine.complete(line));
    await Future<void>.delayed(Duration.zero);
    process.addStdout('line-one\n');
    expect(await firstLine.future, 'line-one');
    await subscription.cancel();

    expect(jobs.terminated, hasLength(1));
    expect(jobs.released, <int>[1]);
    expect(process.killCalls, 0);
  });

  test('cancellation terminates the owned job and waits for exit', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 102);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) => process.complete(exitCode);
    final handle = await OwnedProcessRunner(
      launcher: launcher,
      jobController: jobs,
    ).start('fake-adb', const <String>['logcat']);
    unawaited(handle.stdout.drain<void>());
    unawaited(handle.stderr.drain<void>());

    final exit = await handle.cancel();
    expect(exit.reason, OwnedCommandEndReason.cancelled);
    expect(jobs.terminated, hasLength(1));
    expect(jobs.released, <int>[1]);
    expect(process.killCalls, 0);
    expect(handle.isCompleted, isTrue);
  });

  test('timeout has distinct metadata and terminates the owned job', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 103);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) => process.complete(exitCode);
    final handle = await OwnedProcessRunner(
      launcher: launcher,
      jobController: jobs,
    ).start(
      'fake-adb',
      const <String>['hang'],
      timeout: const Duration(milliseconds: 10),
    );
    unawaited(handle.stdout.drain<void>());
    unawaited(handle.stderr.drain<void>());

    final exit = await handle.done;
    expect(exit.reason, OwnedCommandEndReason.timedOut);
    expect(exit.timedOut, isTrue);
    expect(jobs.terminated, hasLength(1));
  });

  test('attachment failure kills the process and fails closed', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 104);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController()
      ..attachError = StateError('job unavailable');

    await expectLater(
      OwnedProcessRunner(launcher: launcher, jobController: jobs)
          .start('fake-adb', const <String>['logcat']),
      throwsA(isA<OwnedProcessException>()),
    );
    expect(process.killCalls, 1);
    expect(await process.exitCode, -1);
  });

  test('cancellation surfaces unconfirmed native tree cleanup', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 106);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController()
      ..terminateError = StateError('job termination failed');
    final handle = await OwnedProcessRunner(
      launcher: launcher,
      jobController: jobs,
    ).start('fake-adb', const <String>['logcat']);
    final stdoutDrain = handle.stdout.drain<void>();
    final stderrDrain = handle.stderr.drain<void>();

    await expectLater(handle.cancel(), throwsA(isA<OwnedProcessException>()));
    expect(process.killCalls, 1);
    await Future.wait<void>([stdoutDrain, stderrDrain]);
  });

  test('AdbCore pins the explicit serial in the recorded argv', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 105);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    )..setTargetDevice('stale-ui-device');

    final handle = await core.startOwnedProcess(
      const <String>['logcat', '-v', 'threadtime'],
      serial: 'captured-device',
    );
    unawaited(handle.stdout.drain<void>());
    unawaited(handle.stderr.drain<void>());
    await process.complete(0);
    await handle.done;

    expect(
      launcher.launches.single.arguments,
      const <String>[
        '-s',
        'captured-device',
        'logcat',
        '-v',
        'threadtime',
      ],
    );
  });

  test('switching devices cancels old work and pins each command argv',
      () async {
    final launcher = FakeProcessLauncher();
    final oldProcess = FakeProcess(pid: 110);
    final newProcess = FakeProcess(pid: 111);
    launcher.enqueue(oldProcess);
    final jobs = FakeProcessJobController();
    final processes = <int, FakeProcess>{
      oldProcess.pid: oldProcess,
      newProcess.pid: newProcess,
    };
    jobs.onTerminate = (token, exitCode) {
      final pid = jobs.tokenToPid[token];
      return processes[pid]?.complete(exitCode);
    };
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    )..setTargetDevice('device-a');

    final oldCommand = core.runRaw(const <String>['shell', 'slow-command']);
    final oldExpectation = expectLater(
      oldCommand,
      throwsA(
        isA<AdbCommandException>().having(
          (error) => error.message,
          'message',
          contains('deviceTargetChanged'),
        ),
      ),
    );
    core.setTargetDevice('device-b');
    await core.pendingOperationInvalidation;
    await oldExpectation;

    launcher.enqueue(newProcess);
    final newCommand = core.runRaw(const <String>['shell', 'new-command']);
    await newProcess.complete(0);
    expect((await newCommand).exitCode, 0);

    expect(
      launcher.launches.map((launch) => launch.arguments).toList(),
      <List<String>>[
        <String>['-s', 'device-a', 'shell', 'slow-command'],
        <String>['-s', 'device-b', 'shell', 'new-command'],
      ],
    );
    expect(jobs.terminated, hasLength(1));
    expect(core.activeOperationCount, 0);
  });

  test('a cancelled operation cannot launch a process', () async {
    final launcher = FakeProcessLauncher();
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: FakeProcessJobController(),
      ),
    )..setTargetDevice('device-a');
    final operation = core.beginOperation();
    await operation.cancel();

    await expectLater(
      core.runRaw(const <String>['shell', 'never'], operation: operation),
      throwsA(
        isA<AdbCommandException>().having(
          (error) => error.message,
          'message',
          contains('requested'),
        ),
      ),
    );
    expect(launcher.launches, isEmpty);
  });

  test('changing the adb executable invalidates registered operations',
      () async {
    final launcher = FakeProcessLauncher();
    final versionProcess = FakeProcess(pid: 112);
    launcher.enqueue(versionProcess);
    final core = AdbCore(
      adbPath: 'old-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: FakeProcessJobController(),
      ),
    );
    final operation = core.beginOperation(deviceScoped: false);

    core.setAdbPath('new-adb');
    await core.pendingOperationInvalidation;
    expect(
      operation.cancelReason,
      OperationCancelReason.adbExecutableChanged,
    );

    versionProcess.addStdout('Android Debug Bridge version 1.0.41');
    await versionProcess.complete(0);
    for (var i = 0; i < 10 && core.activeOperationCount != 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(launcher.launches.single.executable, 'new-adb');
    expect(launcher.launches.single.arguments, const <String>['version']);
    expect(core.activeOperationCount, 0);
  });

  test('inspector cancellation cleans the remote path on captured device',
      () async {
    final launcher = FakeProcessLauncher();
    final captureProcess = FakeProcess(pid: 113);
    final cleanupProcess = FakeProcess(pid: 114);
    launcher.enqueue(captureProcess);
    launcher.enqueue(cleanupProcess);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) {
      if (jobs.tokenToPid[token] == captureProcess.pid) {
        return captureProcess.complete(exitCode);
      }
      return null;
    };
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    )..setTargetDevice('device-a');

    final dump = core.dumpUi();
    core.setTargetDevice('device-b');
    for (var i = 0; i < 20 && launcher.launches.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(launcher.launches, hasLength(2));
    await cleanupProcess.complete(0);
    await core.pendingOperationInvalidation;

    expect(await dump, isEmpty);
    expect(
      launcher.launches.first.arguments.take(4),
      const <String>['-s', 'device-a', 'shell', 'uiautomator'],
    );
    expect(
      launcher.launches.last.arguments.take(6),
      const <String>['-s', 'device-a', 'shell', 'rm', '-f', '--'],
    );
    expect(core.activeOperationCount, 0);
  });

  test('transfer stop cancels the active owned adb process', () async {
    final launcher = FakeProcessLauncher();
    final pullProcess = FakeProcess(pid: 115);
    launcher.enqueue(pullProcess);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) => pullProcess.complete(exitCode);
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    )..setTargetDevice('device-a');
    final files = AdbFileService(core);
    final transfers = FileTransferProvider();
    addTearDown(transfers.dispose);
    final output = Directory.systemTemp.path.endsWith(Platform.pathSeparator)
        ? '${Directory.systemTemp.path}shirabox_cancel_test.bin'
        : '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'shirabox_cancel_test.bin';
    final jobId = transfers.begin(
      action: 'Downloading',
      total: 1,
      serial: 'device-a',
    )!;
    final operation = core.beginOperation(serial: 'device-a');
    transfers.attachCancellation(jobId, operation.cancel);

    final download = files.pullFile(
      '/sdcard/slow.bin',
      output,
      serial: 'device-a',
      operation: operation,
    );
    final failure = expectLater(download, throwsA(isA<AdbCommandException>()));
    for (var i = 0; i < 1000 && launcher.launches.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(launcher.launches, hasLength(1));
    transfers.requestStop();
    await failure;
    await operation.complete();
    transfers.finish(jobId);

    expect(jobs.terminated, hasLength(1));
    expect(transfers.isBusy, isFalse);
    expect(core.activeOperationCount, 0);
  });

  test('apk install cancellation terminates the active owned process',
      () async {
    final launcher = FakeProcessLauncher();
    final installProcess = FakeProcess(pid: 116);
    launcher.enqueue(installProcess);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) => installProcess.complete(exitCode);
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    )..setTargetDevice('device-a');
    final files = AdbFileService(core);
    final directory = await Directory.systemTemp.createTemp(
      'shirabox_install_cancel_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final apk = File('${directory.path}${Platform.pathSeparator}app.apk');
    await apk.writeAsBytes(const <int>[1, 2, 3]);
    final operation = core.beginOperation(serial: 'device-a');

    final install = files.installApk(
      apk.path,
      serial: 'device-a',
      operation: operation,
    );
    final failure = expectLater(install, throwsA(isA<AdbCommandException>()));
    for (var i = 0; i < 1000 && launcher.launches.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(launcher.launches, hasLength(1));
    await operation.cancel(OperationCancelReason.requested);
    await failure;
    await operation.complete();

    expect(jobs.terminated, hasLength(1));
    expect(core.activeOperationCount, 0);
  });

  test('external owned executable is scoped to its selected device', () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 117);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    final core = AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    )..setTargetDevice('device-a');

    final handle = await core.startOwnedExecutable(
      'wscript',
      const <String>['scrcpy.vbs', '-s', 'device-a'],
      serial: 'device-a',
    );
    unawaited(handle.stdout.drain<void>());
    unawaited(handle.stderr.drain<void>());
    await process.complete(0);
    await handle.done;

    expect(launcher.launches.single.executable, 'wscript');
    expect(
      launcher.launches.single.arguments,
      const <String>['scrcpy.vbs', '-s', 'device-a'],
    );
    for (var i = 0; i < 10 && core.activeOperationCount != 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(core.activeOperationCount, 0);
  });

  test('native job method channel uses scoped attach/terminate/release calls',
      () async {
    const channel = MethodChannel('shirabox/process_job_test');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'attachProcess') return <String, Object?>{'token': 9};
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = NativeProcessJobController(channel: channel);

    final token = await controller.attach(4321);
    await controller.terminate(token!, exitCode: 77);
    await controller.release(token);

    expect(calls.map((call) => call.method), <String>[
      'attachProcess',
      'terminateProcessJob',
      'releaseProcessJob',
    ]);
    expect(calls[0].arguments, <String, Object?>{'pid': 4321});
    expect(calls[1].arguments, <String, Object?>{
      'token': 9,
      'exitCode': 77,
    });
    expect(calls[2].arguments, <String, Object?>{'token': 9});
  });

  test('native launcher subscribes before resume and bridges both pipes',
      () async {
    const methodChannel = MethodChannel('shirabox/process_job_atomic_test');
    const eventChannel = EventChannel('shirabox/process_events_atomic_test');
    final calls = <MethodCall>[];
    MockStreamHandlerEventSink? events;
    var eventSinkReady = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          eventSinkReady = true;
          events = sink;
        },
        onCancel: (_) {
          eventSinkReady = false;
          events = null;
        },
      ),
    );
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'processEventsReady':
          return eventSinkReady;
        case 'launchOwnedProcess':
          return <String, Object?>{'token': 41, 'pid': 2041};
        case 'resumeOwnedProcess':
          expect(events, isNotNull);
          events!.success(<String, Object?>{
            'token': 41,
            'type': 'stdout',
            'data': Uint8List.fromList(utf8.encode('native-out')),
          });
          events!.success(<String, Object?>{
            'token': 41,
            'type': 'stderr',
            'data': Uint8List.fromList(utf8.encode('native-err')),
          });
          events!.success(
            const <String, Object?>{'token': 41, 'type': 'stdoutClosed'},
          );
          events!.success(
            const <String, Object?>{'token': 41, 'type': 'stderrClosed'},
          );
          events!.success(const <String, Object?>{
            'token': 41,
            'type': 'exit',
            'exitCode': 0,
          });
          return null;
        case 'releaseProcessJob':
          return null;
        default:
          fail('Unexpected native process call: ${call.method}');
      }
    });

    final handle = await OwnedProcessRunner(
      launcher: NativeProcessLauncher(
        channel: methodChannel,
        eventChannel: eventChannel,
      ),
      jobController: NativeProcessJobController(channel: methodChannel),
    ).start('fake-adb', const <String>['version']);
    final result = await handle.collect();

    expect(result.pid, 2041);
    expect(result.stdout.decodeUtf8(), 'native-out');
    expect(result.stderr.decodeUtf8(), 'native-err');
    expect(result.exit.treeOwned, isTrue);
    expect(calls.map((call) => call.method), <String>[
      'processEventsReady',
      'launchOwnedProcess',
      'resumeOwnedProcess',
      'releaseProcessJob',
    ]);
  });
}
