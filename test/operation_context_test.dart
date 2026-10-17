import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/services/operation_context.dart';

DeviceTarget _target({
  String? serial = 'device-a',
  int sessionEpoch = 1,
  int adbGeneration = 1,
  bool deviceScoped = true,
}) {
  return DeviceTarget(
    serial: serial,
    sessionEpoch: sessionEpoch,
    adbExecutableGeneration: adbGeneration,
    adbExecutable: 'fake-adb',
    deviceScoped: deviceScoped,
  );
}

void main() {
  test('device targets reject stale device and adb generations', () {
    final target = _target();

    expect(target.isCurrentAgainst(_target()), isTrue);
    expect(
      target.isCurrentAgainst(_target(serial: 'device-b', sessionEpoch: 2)),
      isFalse,
    );
    expect(
      target.isCurrentAgainst(_target(adbGeneration: 2)),
      isFalse,
    );

    final hostTarget = _target(serial: null, deviceScoped: false);
    expect(
      hostTarget.isCurrentAgainst(
        _target(serial: 'device-b', sessionEpoch: 99, deviceScoped: false),
      ),
      isTrue,
    );
  });

  test('cancellation owns resources and cleans them in reverse order',
      () async {
    final registry = OperationRegistry();
    final events = <String>[];
    final operation = registry.begin(target: _target());
    await operation.own(
      cancel: () => events.add('cancel-process'),
      cleanup: () => events.add('cleanup-process'),
    );
    operation.deferCleanup(() => events.add('cleanup-temp-file'));

    await operation.cancel(OperationCancelReason.deviceTargetChanged);

    expect(operation.isCancelled, isTrue);
    expect(
      operation.cancelReason,
      OperationCancelReason.deviceTargetChanged,
    );
    expect(
      events,
      <String>[
        'cancel-process',
        'cleanup-temp-file',
        'cleanup-process',
      ],
    );
    expect(registry.activeCount, 0);
    expect(
      operation.token.throwIfCancelled,
      throwsA(isA<OperationCancelledException>()),
    );
  });

  test('deadline cancellation closes an operation exactly once', () async {
    final registry = OperationRegistry();
    final operation = registry.begin(
      target: _target(),
      deadline: DateTime.now().add(const Duration(milliseconds: 5)),
    );
    var cleanupCount = 0;
    operation.deferCleanup(() => cleanupCount++);

    expect(
      await operation.token.whenCancelled.timeout(const Duration(seconds: 1)),
      OperationCancelReason.deadlineExceeded,
    );
    await operation.complete();

    expect(cleanupCount, 1);
    expect(operation.isClosed, isTrue);
    expect(registry.activeCount, 0);
  });

  test('completion joins cleanup already running during cancellation',
      () async {
    final registry = OperationRegistry();
    final operation = registry.begin(target: _target());
    final cleanupStarted = Completer<void>();
    final allowCleanup = Completer<void>();
    var cleanupCount = 0;
    operation.deferCleanup(() async {
      cleanupCount++;
      cleanupStarted.complete();
      await allowCleanup.future;
    });

    final cancellation =
        operation.cancel(OperationCancelReason.deviceTargetChanged);
    await cleanupStarted.future;
    final completion = operation.complete();
    expect(operation.isClosed, isFalse);
    allowCleanup.complete();
    await Future.wait<void>(<Future<void>>[cancellation, completion]);

    expect(cleanupCount, 1);
    expect(operation.isClosed, isTrue);
    expect(registry.activeCount, 0);
  });
}
