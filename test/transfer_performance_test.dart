import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/services/adb_file.dart';

void main() {
  test('benchmarks local scan and remote manifest decoding', () async {
    final root = await Directory.systemTemp.createTemp(
      'shirabox_transfer_benchmark_',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    const fileCount = 2000;
    for (var index = 0; index < fileCount; index++) {
      await File(
        '${root.path}${Platform.pathSeparator}file_$index.bin',
      ).writeAsBytes(<int>[index & 0xff]);
    }

    final scanWatch = Stopwatch()..start();
    final localManifest = await scanLocalTransferTree(root.path);
    scanWatch.stop();

    final remoteBuffer = StringBuffer();
    for (var index = 0; index < fileCount; index++) {
      remoteBuffer.write('F\u0000/sdcard/source/file_$index.bin\u00001\u0000');
    }
    final remoteBytes = utf8.encode(remoteBuffer.toString());
    final decodeWatch = Stopwatch()..start();
    final decoder = RemoteTreeListingDecoder(
      '/sdcard/source',
      limits: const RecursiveTransferLimits(maxEntries: fileCount + 1),
    );
    decoder.addBytes(remoteBytes);
    final remoteManifest = decoder.finish();
    decodeWatch.stop();

    expect(localManifest.entries, hasLength(fileCount));
    expect(remoteManifest.entries, hasLength(fileCount));
    // These are observations, not CI thresholds; print them for local tuning.
    // ignore: avoid_print
    print(
      'transfer benchmark: local ${scanWatch.elapsedMilliseconds} ms '
      '($fileCount files), remote decoder '
      '${decodeWatch.elapsedMilliseconds} ms (${remoteBytes.length} bytes)',
    );
  });
}
