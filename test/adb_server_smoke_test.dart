import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/owned_process.dart';

void main() {
  final adb = Platform.environment['SHIRABOX_ADB_SERVER_SMOKE'];
  test('shared ADB server survives bootstrap, commands, and runtime disposal',
      () async {
    final reservation =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reservation.port;
    await reservation.close();
    final core = AdbCore(
      adbPath: adb!,
      checkOnCreate: false,
      adbServerPort: port,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: const IoProcessLauncher(),
        jobController: const NoopProcessJobController(),
      ),
    );
    addTearDown(() async {
      await core.disposeRuntime();
      await Process.run(adb, ['-P', '$port', 'kill-server'], runInShell: false);
    });
    await core.ensureServerStarted();
    await _expectServerAlive(port);
    await core.trackDevices().first.timeout(const Duration(seconds: 10));
    await core.listDevices();
    await core.disposeRuntime();
    await _expectServerAlive(port);
  },
      skip: adb == null
          ? 'Set SHIRABOX_ADB_SERVER_SMOKE to an adb.exe path.'
          : false);
}

Future<void> _expectServerAlive(int port) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
      timeout: const Duration(seconds: 2));
  socket.destroy();
}
