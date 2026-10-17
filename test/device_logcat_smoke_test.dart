import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shirabox/providers/logcat_provider.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_process.dart';
import 'package:shirabox/services/owned_process.dart';

void main() {
  final serial = Platform.environment['SHIRABOX_DEVICE_SMOKE_SERIAL'];
  final enabled = serial != null && serial.trim().isNotEmpty;

  test(
    'captures and parses bounded threadtime output from a selected device',
    () async {
      final adbPath = Platform.environment['SHIRABOX_DEVICE_SMOKE_ADB'] ??
          p.join(
            Directory.current.path,
            'windows',
            'resources',
            'scrcpy',
            'adb.exe',
          );
      // `flutter test` does not host the Windows runner MethodChannel. Native
      // Job Object behavior has a separate direct Win32 smoke fixture.
      final core = AdbCore(
        adbPath: adbPath,
        checkOnCreate: false,
        ownedProcessRunner: OwnedProcessRunner(
          launcher: const IoProcessLauncher(),
          jobController: const NoopProcessJobController(),
        ),
      );
      final provider = LogcatProvider(
        AdbProcessService(core),
        maxRetainedEntries: 5000,
        flushInterval: const Duration(milliseconds: 40),
      );
      provider.handleDeviceChange(serial!.trim());
      try {
        provider.startCapture();
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!provider.logs.any(
              (entry) => entry.pid != null && entry.tag != 'Logcat',
            ) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        provider.stopCapture();

        expect(provider.retainedCount, greaterThan(0));
        expect(provider.retainedCount, lessThanOrEqualTo(5000));
        expect(provider.lastError, isNull);
        expect(
          provider.logs.any(
            (entry) => entry.pid != null && entry.tag != 'Logcat',
          ),
          isTrue,
          reason: 'No structured entries in sample:\n'
              '${provider.logs.take(10).map((entry) => entry.raw).join('\n')}',
        );
      } finally {
        provider.dispose();
      }
    },
    skip: enabled
        ? false
        : 'Set SHIRABOX_DEVICE_SMOKE_SERIAL to run the device smoke test.',
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
