import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shirabox/providers/app_state.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_device_tracking.dart';
import 'package:shirabox/services/owned_process.dart';

import 'support/fake_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('tracker decodes split status, frame lengths, and device states', () {
    final decoder = AdbDeviceTrackerDecoder();
    final bytes = utf8.encode('OKAY${_frame('usb-a\tunauthorized\n')}'
        '${_frame('usb-a\tdevice\nwifi-a\toffline\n')}${_frame('')}');
    final snapshots = [
      for (final byte in bytes) ...decoder.add([byte]),
    ];
    expect(snapshots.map((snapshot) => snapshot.connected), [
      [],
      ['usb-a'],
      []
    ]);
    expect(snapshots[0].diagnostic, contains('allow USB debugging'));
    expect(snapshots[1].diagnostic, contains('offline'));
    expect(snapshots[2].diagnostic, isNull);
  });

  test('tracker reports a framed FAIL response', () {
    final decoder = AdbDeviceTrackerDecoder();
    expect(decoder.add(ascii.encode('FAIL0004no')), isEmpty);
    expect(
        () => decoder.add(ascii.encode('pe')),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('nope'))));
  });

  test('shared server bootstrap coalesces callers and survives device changes',
      () async {
    final launcher = FakeProcessLauncher();
    final parent = FakeProcess(pid: 3001);
    launcher.enqueue(parent);
    final jobs = FakeProcessJobController();
    final core = AdbCore(
      checkOnCreate: false,
      serverLauncher: launcher,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: FakeProcessLauncher(),
        jobController: jobs,
      ),
    );
    addTearDown(core.disposeRuntime);
    final first = core.ensureServerStarted();
    final second = core.ensureServerStarted();
    expect(identical(first, second), isTrue);
    core.setTargetDevice('another-device');
    await core.pendingOperationInvalidation;
    expect(parent.killCalls, 0);
    await parent.complete(0);
    await Future.wait([first, second]);
    expect(launcher.launches.single.arguments, ['start-server']);
    expect(jobs.attachedPids, isEmpty);
    expect(core.activeOperationCount, 0);
  });

  test('tracker consumes snapshots without spawning adb devices on every frame',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peerReady = Completer<Socket>();
    final peers = <Socket>[];
    final accepted = server.listen((peer) {
      peers.add(peer);
      var request = '';
      peer.listen((bytes) {
        request += ascii.decode(bytes);
        if (request == '0012host:track-devices' && !peerReady.isCompleted) {
          peerReady.complete(peer);
        }
      });
    });
    final launcher = _CompletingLauncher();
    final jobs = FakeProcessJobController();
    final core = AdbCore(
      checkOnCreate: false,
      adbServerPort: server.port,
      serverLauncher: launcher,
      ownedProcessRunner:
          OwnedProcessRunner(launcher: launcher, jobController: jobs),
    );
    final snapshots = <List<String>>[];
    final ready = Completer<void>();
    final diagnostics = <String>[];
    final sub = core.trackDevices(onDiagnostic: diagnostics.add).listen((ids) {
      snapshots.add(ids);
      if (ids.contains('wifi-a') && !ready.isCompleted) ready.complete();
    });
    addTearDown(() async {
      await sub.cancel();
      for (final peer in peers) {
        peer.destroy();
      }
      await accepted.cancel();
      await server.close();
      await core.disposeRuntime();
    });
    final peer = await peerReady.future.timeout(const Duration(seconds: 5));
    peer.add(utf8.encode('OKAY${_frame('usb-a\tunauthorized\n')}'
        '${_frame('usb-a\tdevice\nwifi-a\tdevice\n')}'));
    await ready.future.timeout(const Duration(seconds: 5));
    expect(snapshots, [
      [],
      ['usb-a', 'wifi-a']
    ]);
    expect(diagnostics.single, contains('allow USB debugging'));
    expect(launcher.launches.map((record) => record.arguments.last),
        ['version', 'start-server']);
    expect(jobs.attachedPids, hasLength(1));
  });

  test('settings load before tracking and ADB path changes restart tracking',
      () async {
    SharedPreferences.setMockInitialValues({'adb_path': 'saved-adb.exe'});
    final core = _StartupCore();
    final state = AppState(core);
    expect(core.trackedExecutables, isEmpty);
    await state.initialized;
    expect(core.trackedExecutables, ['saved-adb.exe']);
    state.updateSettings(adbPath: 'replacement-adb.exe');
    await Future<void>.delayed(Duration.zero);
    expect(core.trackedExecutables, ['saved-adb.exe', 'replacement-adb.exe']);
    expect(core.activeTrackers, 1);
    state.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(core.activeTrackers, 0);
  });
  test('tracker reconnects without reporting a false device disconnect',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final accepted = server.listen((peer) {
      final index = peers.length;
      peers.add(peer);
      var request = '';
      peer.listen((bytes) {
        request += ascii.decode(bytes);
        if (request == '0012host:track-devices') {
          peer.add(utf8.encode('OKAY${_frame('device-$index\tdevice\n')}'));
        }
      });
    });
    final launcher = _CompletingLauncher();
    final core = AdbCore(
      checkOnCreate: false,
      adbServerPort: server.port,
      serverLauncher: launcher,
      ownedProcessRunner: OwnedProcessRunner(
        launcher: launcher,
        jobController: FakeProcessJobController(),
      ),
    );
    final snapshots = <List<String>>[];
    final first = Completer<void>();
    final reconnected = Completer<void>();
    final sub = core.trackDevices().listen((ids) {
      snapshots.add(ids);
      if (ids.contains('device-0') && !first.isCompleted) first.complete();
      if (ids.contains('device-1') && !reconnected.isCompleted) {
        reconnected.complete();
      }
    });
    addTearDown(() async {
      await sub.cancel();
      for (final peer in peers) {
        peer.destroy();
      }
      await accepted.cancel();
      await server.close();
      await core.disposeRuntime();
    });
    await first.future.timeout(const Duration(seconds: 5));
    peers.first.destroy();
    await reconnected.future.timeout(const Duration(seconds: 5));
    expect(snapshots, [
      ['device-0'],
      ['device-1']
    ]);
  });

  test('wireless connect bootstraps the server before connecting', () async {
    final launcher = _CompletingLauncher();
    final jobs = FakeProcessJobController();
    final core = AdbCore(
      checkOnCreate: false,
      serverLauncher: launcher,
      ownedProcessRunner:
          OwnedProcessRunner(launcher: launcher, jobController: jobs),
    );
    addTearDown(core.disposeRuntime);
    core.setTargetDevice('usb-device');
    expect(await core.connect('192.0.2.1:5555'), contains('connected to'));
    expect(launcher.launches.map((record) => record.arguments), [
      ['version'],
      ['start-server'],
      ['connect', '192.0.2.1:5555'],
    ]);
    expect(jobs.attachedPids, hasLength(2));
  });
}

String _frame(String payload) =>
    '${utf8.encode(payload).length.toRadixString(16).padLeft(4, '0')}$payload';

class _CompletingLauncher extends FakeProcessLauncher {
  int nextPid = 3100;

  @override
  Future<Process> start(String executable, List<String> arguments,
      {String? workingDirectory, Map<String, String>? environment}) {
    final process = FakeProcess(pid: nextPid++);
    enqueue(process);
    if (arguments.contains('connect')) {
      process.addStdout('connected to ${arguments.last}\n');
    }
    unawaited(process.complete(0));
    return super.start(executable, arguments,
        workingDirectory: workingDirectory, environment: environment);
  }
}

class _StartupCore extends AdbCore {
  _StartupCore() : super(checkOnCreate: false);

  String selectedExecutable = 'adb';
  final List<String> trackedExecutables = [];
  int activeTrackers = 0;

  @override
  void setAdbPath(String path) {
    selectedExecutable = path;
  }

  @override
  Stream<List<String>> trackDevices({void Function(String)? onDiagnostic}) {
    trackedExecutables.add(selectedExecutable);
    final controller = StreamController<List<String>>();
    controller.onListen = () {
      activeTrackers++;
      controller.add([]);
    };
    controller.onCancel = () {
      activeTrackers--;
    };
    return controller.stream;
  }
}
