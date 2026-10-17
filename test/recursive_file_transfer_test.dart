import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_file.dart';
import 'package:shirabox/services/operation_context.dart';

void main() {
  group('incremental device directory decoding', () {
    test('decodes arbitrarily split UTF-8 frames and exposes entry types', () {
      final decoder = DeviceDirectoryListingDecoder('/sdcard');
      final bytes = utf8.encode(
        'D\u0000/sdcard/照片\u0000'
        'L\u0000/sdcard/link\u0000'
        'F\u0000/sdcard/file.txt\u0000',
      );
      final entries = <AdbFile>[];
      for (final byte in bytes) {
        entries.addAll(decoder.addBytes(<int>[byte]));
      }
      decoder.finish();

      expect(entries, hasLength(3));
      expect(entries[0].name, '照片');
      expect(entries[0].type, AdbFileType.directory);
      expect(entries[1].isSymlink, isTrue);
      expect(entries[2].type, AdbFileType.file);
    });

    test('enforces entry and field limits before unbounded growth', () {
      final entryLimited = DeviceDirectoryListingDecoder(
        '/sdcard',
        maxEntries: 1,
      );
      expect(
        () => entryLimited.addBytes(
          utf8.encode(
            'F\u0000/sdcard/one\u0000F\u0000/sdcard/two\u0000',
          ),
        ),
        throwsFormatException,
      );

      final fieldLimited = DeviceDirectoryListingDecoder(
        '/sdcard',
        maxFieldBytes: 4,
      );
      expect(
        () => fieldLimited.addBytes(utf8.encode('12345')),
        throwsFormatException,
      );
    });
  });

  group('remote recursive manifest decoding', () {
    test('accounts bytes, preserves hierarchy, and skips symlinks', () {
      final decoder = RemoteTreeListingDecoder('/sdcard/source');
      final bytes = utf8.encode(
        'D\u0000/sdcard/source/folder\u00000\u0000'
        'F\u0000/sdcard/source/folder/a.bin\u000012\u0000'
        'L\u0000/sdcard/source/link\u00000\u0000',
      );
      for (var offset = 0; offset < bytes.length; offset += 3) {
        final end = offset + 3 < bytes.length ? offset + 3 : bytes.length;
        decoder.addBytes(
          bytes.sublist(offset, end),
        );
      }
      final manifest = decoder.finish();

      expect(manifest.entries, hasLength(2));
      expect(manifest.totalBytes, 12);
      expect(manifest.skippedSymlinks, 1);
      expect(manifest.entries.last.relativeComponents, ['folder', 'a.bin']);
    });

    test('rejects traversal, excess bytes, depth, and symlinks on request', () {
      expect(
        () => RemoteTreeListingDecoder('/sdcard/source')
          ..addBytes(
            utf8.encode('F\u0000/sdcard/source/../escape\u00001\u0000'),
          ),
        throwsFormatException,
      );

      final byteLimited = RemoteTreeListingDecoder(
        '/sdcard/source',
        limits: const RecursiveTransferLimits(
          maxDepth: 4,
          maxEntries: 4,
          maxTotalBytes: 3,
          maxSingleFileBytes: 3,
        ),
      );
      expect(
        () => byteLimited.addBytes(
          utf8.encode('F\u0000/sdcard/source/file\u00004\u0000'),
        ),
        throwsFormatException,
      );

      final depthLimited = RemoteTreeListingDecoder(
        '/sdcard/source',
        limits: const RecursiveTransferLimits(
          maxDepth: 1,
          maxEntries: 4,
          maxTotalBytes: 4,
          maxSingleFileBytes: 4,
        ),
      );
      expect(
        () => depthLimited.addBytes(
          utf8.encode('F\u0000/sdcard/source/sub/file\u00001\u0000'),
        ),
        throwsFormatException,
      );

      final rejectLinks = RemoteTreeListingDecoder(
        '/sdcard/source',
        symlinkPolicy: RecursiveSymlinkPolicy.reject,
      );
      expect(
        () => rejectLinks.addBytes(
          utf8.encode('L\u0000/sdcard/source/link\u00000\u0000'),
        ),
        throwsFormatException,
      );
    });
  });

  group('local recursive manifest scan', () {
    late Directory temp;
    late Directory root;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('shirabox_tree_test_');
      root = Directory(p.join(temp.path, 'source'));
      await Directory(p.join(root.path, 'sub')).create(recursive: true);
      await File(p.join(root.path, 'top.bin')).writeAsBytes([1, 2, 3]);
      await File(p.join(root.path, 'sub', 'nested.bin')).writeAsBytes([4, 5]);
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('returns stable hierarchy and actual byte total', () async {
      final manifest = await scanLocalTransferTree(root.path);

      expect(manifest.totalBytes, 5);
      expect(manifest.entries, hasLength(3));
      expect(manifest.entries.first.type, AdbFileType.directory);
      expect(
        manifest.entries.map((entry) => entry.relativeComponents.join('/')),
        containsAll(<String>['sub', 'top.bin', 'sub/nested.bin']),
      );
    });

    test('fails preflight when byte, entry, or depth quotas are exceeded', () {
      expect(
        scanLocalTransferTree(
          root.path,
          limits: const RecursiveTransferLimits(
            maxDepth: 3,
            maxEntries: 10,
            maxTotalBytes: 4,
            maxSingleFileBytes: 4,
          ),
        ),
        throwsFormatException,
      );
      expect(
        scanLocalTransferTree(
          root.path,
          limits: const RecursiveTransferLimits(
            maxDepth: 3,
            maxEntries: 2,
            maxTotalBytes: 10,
            maxSingleFileBytes: 10,
          ),
        ),
        throwsFormatException,
      );
      expect(
        scanLocalTransferTree(
          root.path,
          limits: const RecursiveTransferLimits(
            maxDepth: 1,
            maxEntries: 10,
            maxTotalBytes: 10,
            maxSingleFileBytes: 10,
          ),
        ),
        throwsFormatException,
      );
    });

    test('honors cooperative cancellation during preflight', () {
      expect(
        scanLocalTransferTree(root.path, isCancelled: () => true),
        throwsA(isA<TransferCancelledException>()),
      );
    });
  });

  test('batches many small files by remote directory', () async {
    final temp = await Directory.systemTemp.createTemp(
      'shirabox_batch_test_',
    );
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    for (var index = 0; index < 40; index++) {
      await File(p.join(temp.path, 'file_$index.bin')).writeAsBytes(<int>[1]);
    }

    final core = _RecordingAdb();
    await AdbFileService(core).pushDirectory(
      temp.path,
      '/sdcard/Download',
      serial: 'device-a',
    );

    final pushes = core.commands
        .where((args) => args.isNotEmpty && args.first == 'push')
        .toList(growable: false);
    expect(pushes, hasLength(2));
    expect(pushes.first.length, 34); // push + 32 files + remote directory
    expect(pushes.last.length, 10); // push + 8 files + remote directory
    expect(pushes.every((args) => args.last.contains('.shirabox_')), isTrue);
  });
}

class _RecordingAdb extends AdbCore {
  _RecordingAdb() : super(checkOnCreate: false);

  final List<List<String>> commands = <List<String>>[];

  @override
  Future<void> runSafe(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration timeout = const Duration(seconds: 30),
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    commands.add(List<String>.of(args));
    onProgress?.call(1);
  }
}
