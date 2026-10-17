import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_process.dart';
import 'package:shirabox/services/owned_process.dart';

import 'support/fake_process.dart';

void main() {
  test('Logcat records pinned argv and stop awaits owned job termination',
      () async {
    final launcher = FakeProcessLauncher();
    final process = FakeProcess(pid: 201);
    launcher.enqueue(process);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) => process.complete(exitCode);
    final service = AdbProcessService(AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    ));
    final lines = <String>[];
    final done = Completer<void>();
    service.startLogcat(serial: 'pixel-serial').listen(
          lines.add,
          onDone: done.complete,
        );
    await _waitUntil(() => launcher.launches.isNotEmpty);

    process.addStdout(
      '07-20 12:34:56.789  1000  1001 I ActivityManager: ready\n',
    );
    process.addStderr('daemon diagnostic\n');
    await _waitUntil(() => lines.length == 2);
    await service.stopLogcat();
    await done.future;

    expect(
      launcher.launches.single.arguments,
      const <String>[
        '-s',
        'pixel-serial',
        'logcat',
        '-v',
        'threadtime',
      ],
    );
    expect(lines.first, contains('ActivityManager'));
    expect(lines.last, '--- adb: daemon diagnostic');
    expect(jobs.terminated, hasLength(1));
    expect(jobs.released, <int>[1]);
  });

  test('stop waits for a late process start and prevents stale output',
      () async {
    final launcher = FakeProcessLauncher();
    final pendingProcess = Completer<Process>();
    launcher.enqueueFuture(pendingProcess.future);
    final process = FakeProcess(pid: 202);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) => process.complete(exitCode);
    final service = AdbProcessService(AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    ));
    final lines = <String>[];
    final done = Completer<void>();
    service.startLogcat(serial: 'old-device').listen(
          lines.add,
          onDone: done.complete,
        );
    await _waitUntil(() => launcher.launches.isNotEmpty);

    var stopCompleted = false;
    final stop = service.stopLogcat().then((_) => stopCompleted = true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(stopCompleted, isFalse);
    pendingProcess.complete(process);
    await stop;
    await done.future;

    expect(lines, isEmpty);
    expect(jobs.attachedPids, <int>[202]);
    expect(jobs.terminated, hasLength(1));
    expect(process.killCalls, 0);
  });

  test('a replacement capture starts only after the old command exits',
      () async {
    final launcher = FakeProcessLauncher();
    final first = FakeProcess(pid: 203);
    final second = FakeProcess(pid: 204);
    launcher
      ..enqueue(first)
      ..enqueue(second);
    final jobs = FakeProcessJobController();
    jobs.onTerminate = (token, exitCode) {
      final pid = jobs.tokenToPid[token];
      return pid == first.pid
          ? first.complete(exitCode)
          : second.complete(exitCode);
    };
    final service = AdbProcessService(AdbCore(
      adbPath: 'fake-adb',
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: jobs,
      ),
    ));
    final firstDone = Completer<void>();
    service.startLogcat(serial: 'device-a').listen(
          (_) {},
          onDone: firstDone.complete,
        );
    await _waitUntil(() => launcher.launches.length == 1);

    final secondLines = <String>[];
    final secondDone = Completer<void>();
    service.startLogcat(serial: 'device-b').listen(
          secondLines.add,
          onDone: secondDone.complete,
        );
    await _waitUntil(() => launcher.launches.length == 2);
    await firstDone.future;
    second.addStdout(
      '07-20 12:34:56.789  2000  2001 I NewDevice: current\n',
    );
    await _waitUntil(() => secondLines.isNotEmpty);
    await service.stopLogcat();
    await secondDone.future;

    expect(launcher.launches[0].arguments, contains('device-a'));
    expect(launcher.launches[1].arguments, contains('device-b'));
    expect(secondLines.single, contains('NewDevice'));
    expect(jobs.terminated, hasLength(2));
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the fake process lifecycle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
