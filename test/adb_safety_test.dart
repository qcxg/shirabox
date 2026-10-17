import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_file.dart';

void main() {
  group('remote shell quoting', () {
    test('quotes apostrophes without ending the argument', () {
      expect(quoteRemoteShellArg("a'b"), "'a'\"'\"'b'");
    });

    test('rejects NUL', () {
      expect(() => quoteRemoteShellArg('a\u0000b'), throwsFormatException);
    });
  });

  group('NUL-framed device directory listing', () {
    test('preserves newline characters inside a filename', () {
      final files = parseDeviceDirectoryListing(
        'F\u0000/sdcard/line one\nline two.apk\u0000'
            'D\u0000/sdcard/folder\u0000',
        '/sdcard',
      );

      expect(files, hasLength(2));
      expect(files.first.name, 'folder');
      expect(files.last.name, 'line one\nline two.apk');
      expect(files.last.path, '/sdcard/line one\nline two.apk');
    });

    test('rejects entries outside the requested direct parent', () {
      expect(
        () => parseDeviceDirectoryListing(
          'F\u0000/sdcard/sub/child.apk\u0000',
          '/sdcard',
        ),
        throwsFormatException,
      );
      expect(
        () => parseDeviceDirectoryListing(
          'F\u0000/storage/victim.apk\u0000',
          '/sdcard',
        ),
        throwsFormatException,
      );
    });
  });

  group('AdbProgressParser', () {
    test('parses records split across arbitrary chunks', () {
      final parser = AdbProgressParser();
      expect(parser.addBytes(ascii.encode('copy [ 4')), isEmpty);
      expect(parser.addBytes(ascii.encode('2%] file\r')), [0.42]);
      expect(parser.addBytes(ascii.encode('[100%] done')), [1.0]);
    });

    test('does not regress or emit duplicates', () {
      final parser = AdbProgressParser();
      expect(parser.addBytes(ascii.encode('[ 50%]')), [0.5]);
      expect(parser.addBytes(ascii.encode('[ 25%][ 50%]')), isEmpty);
      expect(parser.addBytes(ascii.encode('[ 75%]')), [0.75]);
    });
  });
}
