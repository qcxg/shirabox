import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final mode = arguments.cast<String?>().firstWhere(
        (argument) => argument?.startsWith('fake-') == true,
        orElse: () => null,
      );
  switch (mode) {
    case 'fake-echo-argv':
      stdout.writeln(jsonEncode(arguments));
      await stdout.flush();
      return;
    case 'fake-stream':
      stdout.add(utf8.encode('out-1\n'));
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      stderr.add(utf8.encode('err-1\n'));
      await stderr.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      stdout.add(utf8.encode('out-2\n'));
      await stdout.flush();
      return;
    case 'fake-malformed':
      stdout.add(const <int>[0xff, 0xfe, 0x00, 0x0a]);
      await stdout.flush();
      return;
    case 'fake-fail':
      stderr.writeln('controlled failure');
      await stderr.flush();
      exitCode = 17;
      return;
    case 'fake-flood':
      for (var index = 0; index < 2048; index++) {
        stdout.add(List<int>.filled(1024, index & 0xff));
      }
      await stdout.flush();
      return;
    case 'fake-hang':
      await Future<void>.delayed(const Duration(hours: 1));
      return;
    case 'fake-child':
      await Future<void>.delayed(const Duration(seconds: 30));
      return;
    case 'fake-spawn-child':
      // Delay gives a real owner time to attach this parent to a Job Object;
      // descendants created afterwards inherit membership automatically.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final child = await Process.start(
        Platform.resolvedExecutable,
        const <String>['fake-child'],
        runInShell: false,
      );
      unawaited(child.stdout.drain<void>());
      unawaited(child.stderr.drain<void>());
      stdout.writeln(child.pid);
      await stdout.flush();
      await child.exitCode;
      return;
    default:
      stderr.writeln('Unknown fake ADB invocation: ${jsonEncode(arguments)}');
      await stderr.flush();
      exitCode = 64;
  }
}
