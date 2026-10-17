import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_file.dart';
import 'package:shirabox/services/owned_process.dart';

void main() {
  final serial = Platform.environment['SHIRABOX_DEVICE_SMOKE_SERIAL'];
  final enabled = serial != null && serial.trim().isNotEmpty;

  test(
    'round-trips a nested folder through a selected Android device',
    () async {
      final deviceSerial = serial!.trim();
      final adbPath = Platform.environment['SHIRABOX_DEVICE_SMOKE_ADB'] ??
          p.join(
            Directory.current.path,
            'windows',
            'resources',
            'scrcpy',
            'adb.exe',
          );
      final remoteBase = Platform.environment['SHIRABOX_DEVICE_SMOKE_REMOTE'] ??
          '/sdcard/Download';
      final core = AdbCore(
        adbPath: adbPath,
        checkOnCreate: false,
        ownedProcessRunner: OwnedProcessRunner(
          launcher: const IoProcessLauncher(),
          jobController: const NoopProcessJobController(),
        ),
      );
      final files = AdbFileService(core);
      final localRoot = await Directory.systemTemp.createTemp(
        'shirabox_device_transfer_',
      );
      final uniqueName =
          'shirabox_smoke_${DateTime.now().microsecondsSinceEpoch}';
      final source = Directory(p.join(localRoot.path, uniqueName));
      final nested = Directory(p.join(source.path, '子資料夾'));
      final emptyDirectory = Directory(p.join(source.path, 'empty'));
      final destination = p.join(localRoot.path, 'downloaded');
      final remoteFinal = p.posix.join(remoteBase, uniqueName);
      var published = false;

      await nested.create(recursive: true);
      await emptyDirectory.create();
      await File(p.join(source.path, 'alpha.txt')).writeAsString('alpha\n');
      await File(p.join(nested.path, '照片 名稱.txt')).writeAsBytes(
        List<int>.generate(4096, (index) => index & 0xff),
      );
      await File(p.join(nested.path, 'empty.bin')).create();
      for (var index = 0; index < 40; index++) {
        await File(p.join(source.path, 'small_$index.txt'))
            .writeAsString('small-$index\n');
      }

      final uploadProgress = <double>[];
      final downloadProgress = <double>[];
      try {
        await core.runSafe(
          ['get-state'],
          serial: deviceSerial,
          timeout: const Duration(seconds: 10),
        );
        await files.pushDirectory(
          source.path,
          remoteBase,
          serial: deviceSerial,
          symlinkPolicy: RecursiveSymlinkPolicy.reject,
          onProgress: uploadProgress.add,
        );
        published = true;

        final listed = <AdbFile>[];
        await for (final page in files.listFilePages(
          remoteBase,
          serial: deviceSerial,
          pageSize: 2,
        )) {
          listed.addAll(page.entries);
        }
        expect(
          listed.any(
            (entry) => entry.name == uniqueName && entry.isDir,
          ),
          isTrue,
        );

        await files.pullDirectory(
          remoteFinal,
          destination,
          serial: deviceSerial,
          symlinkPolicy: RecursiveSymlinkPolicy.reject,
          onProgress: downloadProgress.add,
        );

        expect(
          await File(p.join(destination, 'alpha.txt')).readAsString(),
          'alpha\n',
        );
        expect(
          await File(p.join(destination, 'small_39.txt')).readAsString(),
          'small-39\n',
        );
        expect(
          await File(
            p.join(destination, '子資料夾', '照片 名稱.txt'),
          ).readAsBytes(),
          List<int>.generate(4096, (index) => index & 0xff),
        );
        expect(
          await File(
            p.join(destination, '子資料夾', 'empty.bin'),
          ).length(),
          0,
        );
        expect(await Directory(p.join(destination, 'empty')).exists(), isTrue);
        expect(uploadProgress, isNotEmpty);
        expect(downloadProgress, isNotEmpty);
        expect(uploadProgress.last, 1);
        expect(downloadProgress.last, 1);
        _expectMonotonic(uploadProgress);
        _expectMonotonic(downloadProgress);
      } finally {
        if (published) {
          try {
            await files.deleteFile(remoteFinal, serial: deviceSerial);
          } catch (_) {}
        }
        if (await localRoot.exists()) {
          await localRoot.delete(recursive: true);
        }
      }
    },
    skip: enabled
        ? false
        : 'Set SHIRABOX_DEVICE_SMOKE_SERIAL to run the device smoke test.',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _expectMonotonic(List<double> values) {
  for (var index = 1; index < values.length; index++) {
    expect(values[index], greaterThanOrEqualTo(values[index - 1]));
  }
}
