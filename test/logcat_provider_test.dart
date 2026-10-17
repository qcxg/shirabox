import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shirabox/providers/logcat_provider.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_process.dart';

void main() {
  group('LogcatLineParser', () {
    test('parses threadtime PID, TID, level, tag, and message', () {
      final entry = LogcatLineParser().parse(
        '07-19 12:34:56.789  1234  5678 E ActivityManager: App crashed',
        7,
      )!;

      expect(entry.sequence, 7);
      expect(entry.time, '07-19 12:34:56.789');
      expect(entry.pid, 1234);
      expect(entry.tid, 5678);
      expect(entry.level, LogLevel.error);
      expect(entry.tag, 'ActivityManager');
      expect(entry.msg, 'App crashed');
    });

    test('keeps unstructured and ADB diagnostic lines visible', () {
      final parser = LogcatLineParser();
      expect(
        parser.parse('native stack continuation', 1)!.tag,
        'Logcat',
      );
      final diagnostic = parser.parse('--- adb: transport closed', 2)!;
      expect(diagnostic.tag, 'ADB');
      expect(diagnostic.level, LogLevel.warn);
      expect(
        parser.parse('--------- beginning of main', 3),
        isNull,
      );
    });
  });

  group('LogcatFilter', () {
    final matching = LogEntry(
      sequence: 1,
      time: '07-19 12:34:56.789',
      pid: 1234,
      tid: 5678,
      level: LogLevel.error,
      tag: 'ActivityManager',
      msg: 'Application not responding',
    );
    final noise = LogEntry(
      sequence: 2,
      time: '07-19 12:34:57.000',
      pid: 999,
      tid: 999,
      level: LogLevel.debug,
      tag: 'Noise',
      msg: 'Application not responding noise',
    );

    test('supports fields, quotes, exact process IDs, levels, and exclusion',
        () {
      final filter = LogcatFilter.compile(
        query: 'tag:activity msg:"not responding" pid:1234 '
            'level:E,F -noise',
        minLevel: LogLevel.verbose,
        mode: LogcatFilterMode.terms,
        caseSensitive: false,
      );

      expect(filter.matches(matching), isTrue);
      expect(filter.matches(noise), isFalse);
    });

    test('supports regular expressions and rejects malformed filters', () {
      final regex = LogcatFilter.compile(
        query: r'Activity.*responding',
        minLevel: LogLevel.verbose,
        mode: LogcatFilterMode.regularExpression,
        caseSensitive: true,
      );
      expect(regex.matches(matching), isTrue);
      expect(
        () => LogcatFilter.compile(
          query: '[',
          minLevel: LogLevel.verbose,
          mode: LogcatFilterMode.regularExpression,
          caseSensitive: false,
        ),
        throwsFormatException,
      );
      expect(
        () => LogcatFilter.compile(
          query: 'tag:"unterminated',
          minLevel: LogLevel.verbose,
          mode: LogcatFilterMode.terms,
          caseSensitive: false,
        ),
        throwsFormatException,
      );
    });
  });

  test('provider filters incrementally and evicts retained entries in batches',
      () async {
    final source = _FakeLogcatService();
    final provider = LogcatProvider(
      source,
      maxRetainedEntries: 3,
      maxPendingLines: 20,
      maxLinesPerFlush: 20,
      flushInterval: const Duration(milliseconds: 1),
    );
    addTearDown(() async {
      provider.dispose();
      await source.disposeSource();
    });
    provider.handleDeviceChange('device-a');
    provider.startCapture();

    source.add(_line(1, 'Keep', 'first'));
    source.add(_line(2, 'Other', 'second'));
    source.add(_line(3, 'Keep', 'third'));
    await _waitForFlush();
    provider.setFilter(query: 'tag:Keep');
    expect(provider.logs.map((entry) => entry.msg), ['first', 'third']);

    source.add(_line(4, 'Keep', 'fourth'));
    await _waitForFlush();
    expect(provider.retainedCount, 3);
    expect(provider.logs.map((entry) => entry.msg), ['third', 'fourth']);

    source.add(_line(5, 'Other', 'fifth'));
    await _waitForFlush();
    expect(provider.retainedCount, 3);
    expect(provider.logs.map((entry) => entry.msg), ['third', 'fourth']);
  });

  test('provider bounds pending input and records dropped lines', () async {
    final source = _FakeLogcatService();
    final provider = LogcatProvider(
      source,
      maxRetainedEntries: 20,
      maxPendingLines: 2,
      maxLinesPerFlush: 20,
      flushInterval: const Duration(minutes: 1),
    );
    addTearDown(() async {
      provider.dispose();
      await source.disposeSource();
    });
    provider.handleDeviceChange('device-a');
    provider.startCapture();

    source.add(_line(1, 'Burst', 'one'));
    source.add(_line(2, 'Burst', 'two'));
    source.add(_line(3, 'Burst', 'three'));
    provider.stopCapture();

    expect(provider.totalReceivedLines, 3);
    expect(provider.droppedPendingLines, 1);
    expect(provider.logs.first.tag, 'Shirabox');
    expect(provider.logs.map((entry) => entry.msg), contains('two'));
    expect(provider.logs.map((entry) => entry.msg), contains('three'));
  });

  test('100,000-line bursts remain bounded and filter retained data', () async {
    final source = _FakeLogcatService();
    final provider = LogcatProvider(
      source,
      maxRetainedEntries: 5000,
      maxPendingLines: 12000,
      maxLinesPerFlush: 12000,
      flushInterval: const Duration(minutes: 1),
    );
    addTearDown(() async {
      provider.dispose();
      await source.disposeSource();
    });
    provider.handleDeviceChange('device-a');
    provider.startCapture();

    for (var index = 0; index < 100000; index++) {
      source.add(_line(
        index,
        index % 100 == 0 ? 'Needle' : 'Bulk',
        'message $index',
      ));
    }
    provider.stopCapture();
    expect(provider.totalReceivedLines, 100000);
    expect(provider.droppedPendingLines, 88000);
    expect(provider.retainedCount, 5000);
    expect(provider.logs, hasLength(5000));

    provider.setFilter(query: 'tag:Needle');
    expect(provider.logs, hasLength(50));
    expect(provider.logs.every((entry) => entry.tag == 'Needle'), isTrue);
  });
}

String _line(int index, String tag, String message) {
  return '07-19 12:34:56.789  ${1000 + index}  ${2000 + index} '
      'I $tag: $message';
}

Future<void> _waitForFlush() =>
    Future<void>.delayed(const Duration(milliseconds: 15));

class _FakeLogcatService extends AdbProcessService {
  _FakeLogcatService() : super(AdbCore(checkOnCreate: false));

  final StreamController<String> _controller =
      StreamController<String>(sync: true);
  int stopCalls = 0;

  void add(String line) => _controller.add(line);

  @override
  Stream<String> startLogcat({String? filter, String? serial}) {
    return _controller.stream;
  }

  @override
  Future<void> stopLogcat() async {
    stopCalls++;
  }

  Future<void> disposeSource() => _controller.close();
}
