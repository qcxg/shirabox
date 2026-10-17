import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shirabox/services/local_path_codec.dart';

void main() {
  group('encodeRemoteNameForLocal', () {
    test('keeps ordinary Unicode names readable', () {
      expect(
        encodeRemoteNameForLocal('照片😀.jpg', windows: true),
        '照片😀.jpg',
      );
    });

    test('escapes Windows separators, metacharacters, and percent', () {
      expect(
        encodeRemoteNameForLocal(r'..\a:b*%?.apk', windows: true),
        '..%5Ca%3Ab%2A%25%3F.apk',
      );
    });

    test('escapes reserved names and trailing dot or space', () {
      expect(
        encodeRemoteNameForLocal('CON.txt', windows: true),
        '%43ON.txt',
      );
      expect(
        encodeRemoteNameForLocal('CON .txt', windows: true),
        '%43ON .txt',
      );
      expect(
        encodeRemoteNameForLocal('name. ', windows: true),
        'name.%20',
      );
    });

    test('bounds expansion deterministically', () {
      final input = List.filled(255, '%').join();
      final first = encodeRemoteNameForLocal(input, windows: true);
      final second = encodeRemoteNameForLocal(input, windows: true);
      expect(first, second);
      expect(first.length, lessThanOrEqualTo(180));
    });
  });

  test('download destination remains contained and collision free', () async {
    final temp = await Directory.systemTemp.createTemp('shirabox_codec_test_');
    addTearDown(() => temp.delete(recursive: true));
    final reserved = <String>{};

    final first = await chooseLocalDownloadPath(
      temp.path,
      r'..\outside',
      reservedPaths: reserved,
      windows: true,
    );
    final second = await chooseLocalDownloadPath(
      temp.path,
      r'..\outside',
      reservedPaths: reserved,
      windows: true,
    );

    expect(p.isWithin(p.absolute(temp.path), first), isTrue);
    expect(p.isWithin(p.absolute(temp.path), second), isTrue);
    expect(first, isNot(second));
  });
}
