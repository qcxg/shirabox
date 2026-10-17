import 'package:shirabox/providers/file_transfer_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one persistent transfer job owns progress and rejects overlap', () {
    final transfers = FileTransferProvider();
    addTearDown(transfers.dispose);

    final first = transfers.begin(
      action: 'Downloading',
      total: 2,
      serial: 'device-a',
    );
    expect(first, isNotNull);
    expect(
      transfers.begin(action: 'Uploading', total: 1, serial: 'device-a'),
      isNull,
    );

    transfers.beginItem(first!, 'one.apk');
    transfers.updateProgress(first, 0.5);
    expect(transfers.currentName, 'one.apk');
    expect(transfers.currentItemProgress, 0.5);

    transfers.completeItem(first, success: false);
    expect(transfers.completed, 1);
    expect(transfers.failures, 1);
  });

  test('stop cancels active work and stale job callbacks are ignored',
      () async {
    final transfers = FileTransferProvider();
    addTearDown(transfers.dispose);

    final first = transfers.begin(
      action: 'Uploading',
      total: 3,
      serial: 'device-a',
    )!;
    var cancelCalls = 0;
    transfers.attachCancellation(first, () async => cancelCalls++);
    transfers.requestStop();
    await Future<void>.delayed(Duration.zero);
    expect(transfers.shouldStop(first), isTrue);
    expect(cancelCalls, 1);
    transfers.finish(first);

    final second = transfers.begin(
      action: 'Downloading',
      total: 1,
      serial: 'device-b',
    )!;
    transfers.completeItem(first, success: true);
    expect(transfers.completed, 0);
    expect(transfers.owns(second), isTrue);
  });

  test('cancelled items are tracked separately and new jobs notify progress',
      () {
    final transfers = FileTransferProvider();
    addTearDown(transfers.dispose);
    var notifications = 0;
    transfers.addListener(() => notifications++);

    final first = transfers.begin(
      action: 'Uploading',
      total: 1,
      serial: 'device-a',
    )!;
    transfers.beginItem(first, 'folder');
    transfers.completeItem(first, success: false, wasCancelled: true);
    expect(transfers.cancelled, 1);
    expect(transfers.failures, 0);
    transfers.finish(first);

    final second = transfers.begin(
      action: 'Downloading',
      total: 1,
      serial: 'device-a',
    )!;
    transfers.beginItem(second, 'file.bin');
    final beforeProgress = notifications;
    transfers.updateProgress(second, 0.01);
    expect(transfers.currentItemProgress, 0.01);
    expect(notifications, beforeProgress + 1);
  });
}
