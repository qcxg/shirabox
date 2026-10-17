import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/services/ascii_staging.dart';

const _channel = MethodChannel('shirabox/native_staging');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final createdPaths = <String>[];
  final calls = <MethodCall>[];

  setUp(() {
    createdPaths.clear();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      switch (call.method) {
        case 'createAdbStagingDirectory':
          final prefix = arguments['prefix']! as String;
          final directory = await Directory.systemTemp.createTemp(prefix);
          createdPaths.add(directory.path);
          return directory.path;
        case 'deleteAdbStagingDirectory':
          final path = arguments['path']! as String;
          final directory = Directory(path);
          if (await directory.exists()) {
            await directory.delete(
              recursive: arguments['recursive']! as bool,
            );
          }
          return null;
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    for (final path in createdPaths) {
      final directory = Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('rejects a non-ASCII staging prefix before invoking native code',
      () async {
    await expectLater(
      createAdbSafeTempDirectory('安裝_'),
      throwsFormatException,
    );
    expect(calls, isEmpty);
  });

  test('uses native creation and owned cleanup on Windows', () async {
    final directory = await createAdbSafeTempDirectory('shirabox_test_');
    try {
      expect(await directory.exists(), isTrue);
      expect(
        await FileSystemEntity.type(directory.path, followLinks: false),
        FileSystemEntityType.directory,
      );
      if (Platform.isWindows) {
        expect(directory.path.codeUnits.every((unit) => unit <= 0x7f), isTrue);
        expect(calls.single.method, 'createAdbStagingDirectory');
        expect(calls.single.arguments, {'prefix': 'shirabox_test_'});
      }
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }

    if (Platform.isWindows) {
      expect(calls.last.method, 'deleteAdbStagingDirectory');
      expect(
        calls.last.arguments,
        {'path': directory.path, 'recursive': true},
      );
    }
  });

  test('rejects an invalid path returned across the native boundary', () async {
    if (!Platform.isWindows) {
      return;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => r'relative\stage');

    await expectLater(
      createAdbSafeTempDirectory('shirabox_test_'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
