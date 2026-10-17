import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/owned_process.dart';

void main() {
  late String fakeAdb;

  setUpAll(() async {
    fakeAdb = await _buildFakeAdb();
  });

  test('real fake executable records exact serial-scoped argv', () async {
    final core = _fakeCore(fakeAdb);
    final command = await core.startOwnedProcess(
      const <String>['fake-echo-argv'],
      serial: 'device with spaces',
    );
    final stdoutText = command.stdout.transform(utf8.decoder).join();
    final stderrDrain = command.stderr.drain<void>();
    final exit = await command.done;

    expect(exit.exitCode, 0);
    expect(exit.reason, OwnedCommandEndReason.exited);
    expect(jsonDecode(await stdoutText), <String>[
      '-s',
      'device with spaces',
      'fake-echo-argv',
    ]);
    await stderrDrain;
  });

  test('real fake executable streams both pipes without deadlock', () async {
    final command = await _fakeCore(fakeAdb).startOwnedProcess(
      const <String>['fake-stream'],
      includeTarget: false,
    );
    final stdoutText = command.stdout.transform(utf8.decoder).join();
    final stderrText = command.stderr.transform(utf8.decoder).join();
    final exit = await command.done;

    expect(exit.exitCode, 0);
    expect(await stdoutText, 'out-1\nout-2\n');
    expect(await stderrText, 'err-1\n');
  });

  test('real fake executable preserves malformed bytes', () async {
    final command = await _fakeCore(fakeAdb).startOwnedProcess(
      const <String>['fake-malformed'],
      includeTarget: false,
    );
    final bytes = command.stdout.expand((chunk) => chunk).toList();
    final stderrDrain = command.stderr.drain<void>();
    await command.done;

    expect(await bytes, const <int>[0xff, 0xfe, 0x00, 0x0a]);
    await stderrDrain;
  });

  test('real hanging process receives timeout and confirmed exit', () async {
    final command = await _fakeCore(fakeAdb).startOwnedProcess(
      const <String>['fake-hang'],
      includeTarget: false,
      timeout: const Duration(milliseconds: 100),
    );
    final stdoutDrain = command.stdout.drain<void>();
    final stderrDrain = command.stderr.drain<void>();
    final exit = await command.done;

    expect(exit.reason, OwnedCommandEndReason.timedOut);
    expect(command.isCompleted, isTrue);
    await Future.wait<void>([stdoutDrain, stderrDrain]);
  });

  test('pre-listener flood is drained into a bounded replay buffer', () async {
    final command = await _fakeCore(fakeAdb).startOwnedProcess(
      const <String>['fake-flood'],
      includeTarget: false,
    );
    await command.done;
    await Future.wait<void>([command.stdoutDone, command.stderrDone]);
    final bytes = await command.stdout.expand((chunk) => chunk).toList();

    expect(bytes, isNotEmpty);
    expect(bytes.length, lessThanOrEqualTo(1024 * 1024));
  });
}

AdbCore _fakeCore(String executable) => AdbCore(
      adbPath: executable,
      checkOnCreate: false,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: const IoProcessLauncher(),
        jobController: const NoopProcessJobController(),
      ),
    );

Future<String> _buildFakeAdb() async {
  final source = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'fake_adb.dart',
  );
  final outputDirectory = Directory(p.join(
    Directory.current.path,
    'build',
    'test_tools',
  ));
  await outputDirectory.create(recursive: true);
  final output = p.join(outputDirectory.path, 'fake_adb.exe');
  final outputFile = File(output);
  if (outputFile.existsSync() &&
      outputFile.lastModifiedSync().isAfter(File(source).lastModifiedSync())) {
    return output;
  }

  final dart = _findDartExecutable();
  final result = await Process.run(
    dart,
    <String>['compile', 'exe', source, '-o', output],
    runInShell: false,
  );
  if (result.exitCode != 0 || !outputFile.existsSync()) {
    fail('Unable to compile fake ADB.\n${result.stdout}\n${result.stderr}');
  }
  return output;
}

String _findDartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    for (final relative in <List<String>>[
      <String>['dart-sdk', 'bin', 'dart.exe'],
      <String>['bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'],
    ]) {
      final candidate = File(p.joinAll(<String>[directory.path, ...relative]));
      if (candidate.existsSync()) return candidate.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Unable to locate dart.exe for the fake ADB fixture.');
}
