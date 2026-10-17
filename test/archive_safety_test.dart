import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shirabox/services/adb_file.dart';

int _findEocd(Uint8List bytes) {
  const eocdLength = 22;
  for (var index = bytes.length - eocdLength; index >= 0; index--) {
    if (bytes[index] == 0x50 &&
        bytes[index + 1] == 0x4b &&
        bytes[index + 2] == 0x05 &&
        bytes[index + 3] == 0x06) {
      return index;
    }
  }
  throw StateError('Test archive has no EOCD record.');
}

Uint8List _encodeArchive(int entryCount) {
  final archive = Archive();
  for (var index = 0; index < entryCount; index++) {
    archive.addFile(ArchiveFile.bytes('entry_$index.apk', const <int>[]));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

int _centralDirectoryOffset(Uint8List bytes) {
  final eocd = _findEocd(bytes);
  return ByteData.sublistView(bytes).getUint32(eocd + 16, Endian.little);
}

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('archive_test_');
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('ZIP preflight accepts a small ordinary install archive', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('base.apk', <int>[1, 2, 3]));
    final file = File(p.join(tempDirectory.path, 'valid.apks'));
    await file.writeAsBytes(ZipEncoder().encode(archive));

    await expectLater(preflightInstallArchive(file), completes);
  });

  test('ZIP preflight rejects excessive central-directory entries', () async {
    final file = File(p.join(tempDirectory.path, 'too_many.apks'));
    await file.writeAsBytes(_encodeArchive(1025));

    await expectLater(
      preflightInstallArchive(file),
      throwsFormatException,
    );
  });

  test('ZIP preflight scans records when EOCD forges a safe count', () async {
    final bytes = _encodeArchive(1025);
    final eocd = _findEocd(bytes);
    final data = ByteData.sublistView(bytes);
    data.setUint16(eocd + 8, 1, Endian.little);
    data.setUint16(eocd + 10, 1, Endian.little);
    final file = File(p.join(tempDirectory.path, 'forged_count.apks'));
    await file.writeAsBytes(bytes);

    await expectLater(
      preflightInstallArchive(file),
      throwsFormatException,
    );
  });

  test('ZIP preflight requires EOCD count to equal scanned records', () async {
    final bytes = _encodeArchive(2);
    final eocd = _findEocd(bytes);
    final data = ByteData.sublistView(bytes);
    data.setUint16(eocd + 8, 1, Endian.little);
    data.setUint16(eocd + 10, 1, Endian.little);
    final file = File(p.join(tempDirectory.path, 'mismatched_count.apks'));
    await file.writeAsBytes(bytes);

    await expectLater(
      preflightInstallArchive(file),
      throwsFormatException,
    );
  });

  test('ZIP preflight rejects an invalid central record signature', () async {
    final bytes = _encodeArchive(1);
    bytes[_centralDirectoryOffset(bytes)] = 0;
    final file = File(p.join(tempDirectory.path, 'bad_signature.apks'));
    await file.writeAsBytes(bytes);

    await expectLater(
      preflightInstallArchive(file),
      throwsFormatException,
    );
  });

  test('ZIP preflight rejects a central record beyond its boundary', () async {
    final bytes = _encodeArchive(1);
    final centralOffset = _centralDirectoryOffset(bytes);
    ByteData.sublistView(
      bytes,
    ).setUint16(centralOffset + 28, 0xffff, Endian.little);
    final file = File(p.join(tempDirectory.path, 'bad_record_length.apks'));
    await file.writeAsBytes(bytes);

    await expectLater(
      preflightInstallArchive(file),
      throwsFormatException,
    );
  });

  test('ZIP preflight rejects a missing central directory', () async {
    final file = File(p.join(tempDirectory.path, 'truncated.apks'));
    await file.writeAsBytes(List<int>.filled(64, 0));

    await expectLater(
      preflightInstallArchive(file),
      throwsFormatException,
    );
  });
}
