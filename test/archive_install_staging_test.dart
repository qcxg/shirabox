import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/operation_context.dart';
import 'package:shirabox/services/adb_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shirabox/native_staging');
  late Directory testRoot;
  final nativeCalls = <MethodCall>[];
  final stagingPaths = <String>[];

  setUp(() async {
    testRoot = await Directory.systemTemp.createTemp('archive_install_test_');
    nativeCalls.clear();
    stagingPaths.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      if (call.method == 'createAdbStagingDirectory') {
        final directory = await Directory.systemTemp.createTemp(
          arguments['prefix']! as String,
        );
        stagingPaths.add(directory.path);
        return directory.path;
      }
      if (call.method == 'deleteAdbStagingDirectory') {
        final directory = Directory(arguments['path']! as String);
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
        .setMockMethodCallHandler(channel, null);
    for (final path in stagingPaths) {
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    if (await testRoot.exists()) await testRoot.delete(recursive: true);
  });

  test(
    'creates and owns archive staging on the root isolate',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('base.apk', <int>[1, 2, 3, 4]));
      final input = File(p.join(testRoot.path, 'package.xapk'));
      await input.writeAsBytes(ZipEncoder().encode(archive));
      final core = _InstallSessionAdb();
      final progress = <double>[];

      await AdbFileService(core).installXapk(
        input.path,
        serial: 'device-a',
        onProgress: progress.add,
      );

      expect(nativeCalls.map((call) => call.method), <String>[
        'createAdbStagingDirectory',
        'deleteAdbStagingDirectory',
      ]);
      final createdPath = core.pushedLocalPath;
      expect(createdPath, isNotNull);
      expect(p.basename(createdPath!), 'apk_0000.apk');
      expect(await Directory(p.dirname(createdPath)).exists(), isFalse);
      expect(core.committed, isTrue);
      expect(progress.last, 1);
    },
    skip: Platform.isWindows
        ? false
        : 'Native staging isolate ownership is Windows-specific.',
  );
}

class _InstallSessionAdb extends AdbCore {
  _InstallSessionAdb() : super(checkOnCreate: false);

  String? pushedLocalPath;
  bool committed = false;

  @override
  Future<ProcessResult> runRaw(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration timeout = const Duration(seconds: 30),
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    if (args.length >= 3 &&
        args[0] == 'shell' &&
        args[1] == 'pm' &&
        args[2] == 'install-create') {
      return ProcessResult(0, 0, 'Success: created install session [42]', '');
    }
    if (args.length >= 3 &&
        args[0] == 'shell' &&
        args[1] == 'pm' &&
        args[2] == 'install-commit') {
      committed = true;
      return ProcessResult(0, 0, 'Success', '');
    }
    throw StateError('Unexpected raw command: $args');
  }

  @override
  Future<void> runSafe(
    List<String> args, {
    String? serial,
    bool includeTarget = true,
    Duration timeout = const Duration(seconds: 30),
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    if (args.isNotEmpty && args.first == 'push') {
      pushedLocalPath = args[1];
      onProgress?.call(1);
    }
  }
}
