import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/adb_process.dart';

enum LogLevel {
  verbose('V', Color(0xFFB8B8B8)),
  debug('D', Color(0xFF64B5F6)),
  info('I', Color(0xFF81C784)),
  warn('W', Color(0xFFFFD180)),
  error('E', Color(0xFFFF8A80)),
  fatal('F', Color(0xFFEF5350));

  const LogLevel(this.code, this.color);

  final String code;
  final Color color;

  static LogLevel fromCode(String code) {
    final normalized = code.toUpperCase();
    if (normalized == 'A') return LogLevel.fatal;
    return LogLevel.values.firstWhere(
      (level) => level.code == normalized,
      orElse: () => LogLevel.info,
    );
  }
}

enum LogcatFilterMode { terms, regularExpression }

@immutable
class LogEntry {
  LogEntry({
    required this.sequence,
    required this.time,
    required this.level,
    required this.tag,
    required this.msg,
    this.pid,
    this.tid,
    String? raw,
  })  : raw = raw ?? msg,
        searchText = [
          time,
          if (pid != null) pid.toString(),
          if (tid != null) tid.toString(),
          level.code,
          level.name,
          tag,
          msg,
        ].join('\n'),
        foldedTag = tag.toLowerCase(),
        foldedMessage = msg.toLowerCase(),
        foldedSearchText = [
          time,
          if (pid != null) pid.toString(),
          if (tid != null) tid.toString(),
          level.code,
          level.name,
          tag,
          msg,
        ].join('\n').toLowerCase();

  final int sequence;
  final String time;
  final int? pid;
  final int? tid;
  final LogLevel level;
  final String tag;
  final String msg;
  final String raw;
  final String searchText;
  final String foldedTag;
  final String foldedMessage;
  final String foldedSearchText;

  String get formattedLine {
    final process = pid == null
        ? ''
        : ' ${pid.toString().padLeft(5)}'
            '${tid == null ? '' : '/${tid.toString().padRight(5)}'}';
    return '$time$process ${level.code}/$tag: $msg'.trimLeft();
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'sequence': sequence,
        'time': time,
        'pid': pid,
        'tid': tid,
        'level': level.code,
        'tag': tag,
        'message': msg,
      };
}

class LogcatLineParser {
  static final RegExp _threadTime = RegExp(
    r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+'
    r'(\d+)\s+(\d+)\s+([VDIWEFA])\s+(.+?):\s?(.*)$',
  );
  static final RegExp _briefWithTime = RegExp(
    r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+'
    r'([VDIWEFA])/(.*?)\(\s*(\d+)\):\s?(.*)$',
  );
  static final RegExp _brief = RegExp(
    r'^([VDIWEFA])/(.*?)\(\s*(\d+)\):\s?(.*)$',
  );

  LogEntry? parse(String line, int sequence) {
    if (line.isEmpty || line.startsWith('--------- beginning of ')) {
      return null;
    }
    if (line.startsWith('--- adb:')) {
      return LogEntry(
        sequence: sequence,
        time: '',
        level: LogLevel.warn,
        tag: 'ADB',
        msg: line.substring('--- adb:'.length).trim(),
        raw: line,
      );
    }

    var match = _threadTime.firstMatch(line);
    if (match != null) {
      return LogEntry(
        sequence: sequence,
        time: match.group(1)!,
        pid: int.tryParse(match.group(2)!),
        tid: int.tryParse(match.group(3)!),
        level: LogLevel.fromCode(match.group(4)!),
        tag: match.group(5)!.trim(),
        msg: match.group(6)!,
        raw: line,
      );
    }

    match = _briefWithTime.firstMatch(line);
    if (match != null) {
      return LogEntry(
        sequence: sequence,
        time: match.group(1)!,
        pid: int.tryParse(match.group(4)!),
        level: LogLevel.fromCode(match.group(2)!),
        tag: match.group(3)!.trim(),
        msg: match.group(5)!,
        raw: line,
      );
    }

    match = _brief.firstMatch(line);
    if (match != null) {
      return LogEntry(
        sequence: sequence,
        time: '',
        pid: int.tryParse(match.group(3)!),
        level: LogLevel.fromCode(match.group(1)!),
        tag: match.group(2)!.trim(),
        msg: match.group(4)!,
        raw: line,
      );
    }

    return LogEntry(
      sequence: sequence,
      time: '',
      level: LogLevel.info,
      tag: 'Logcat',
      msg: line,
      raw: line,
    );
  }
}

class LogcatFilter {
  LogcatFilter._({
    required this.query,
    required this.minLevel,
    required this.mode,
    required this.caseSensitive,
    required List<_LogcatFilterClause> clauses,
    this.expression,
  }) : _clauses = List.unmodifiable(clauses);

  factory LogcatFilter.compile({
    required String query,
    required LogLevel minLevel,
    required LogcatFilterMode mode,
    required bool caseSensitive,
  }) {
    final trimmed = query.trim();
    if (mode == LogcatFilterMode.regularExpression && trimmed.isNotEmpty) {
      return LogcatFilter._(
        query: query,
        minLevel: minLevel,
        mode: mode,
        caseSensitive: caseSensitive,
        clauses: const <_LogcatFilterClause>[],
        expression: RegExp(trimmed, caseSensitive: caseSensitive),
      );
    }

    final clauses = <_LogcatFilterClause>[];
    for (var token in _tokenizeFilter(trimmed)) {
      var excluded = false;
      if (token.startsWith('-') && token.length > 1) {
        excluded = true;
        token = token.substring(1);
      }
      if (token.isEmpty) continue;

      String? field;
      var value = token;
      final separator = token.indexOf(':');
      if (separator > 0) {
        final candidate = token.substring(0, separator).toLowerCase();
        if (const <String>{'tag', 'msg', 'message', 'pid', 'tid', 'level'}
            .contains(candidate)) {
          field = candidate == 'message' ? 'msg' : candidate;
          value = token.substring(separator + 1);
          if (value.isEmpty) {
            throw FormatException('Filter field "$candidate" is empty.');
          }
        }
      }
      clauses.add(_LogcatFilterClause(
        field: field,
        value: caseSensitive ? value : value.toLowerCase(),
        excluded: excluded,
      ));
    }
    return LogcatFilter._(
      query: query,
      minLevel: minLevel,
      mode: mode,
      caseSensitive: caseSensitive,
      clauses: clauses,
    );
  }

  final String query;
  final LogLevel minLevel;
  final LogcatFilterMode mode;
  final bool caseSensitive;
  final RegExp? expression;
  final List<_LogcatFilterClause> _clauses;

  bool matches(LogEntry entry) {
    if (entry.level.index < minLevel.index) return false;
    final regex = expression;
    if (regex != null) return regex.hasMatch(entry.formattedLine);

    for (final clause in _clauses) {
      final matched = _matchesClause(entry, clause);
      if (clause.excluded ? matched : !matched) return false;
    }
    return true;
  }

  bool _matchesClause(LogEntry entry, _LogcatFilterClause clause) {
    final value = clause.value;
    switch (clause.field) {
      case 'tag':
        return (caseSensitive ? entry.tag : entry.foldedTag).contains(value);
      case 'msg':
        return (caseSensitive ? entry.msg : entry.foldedMessage)
            .contains(value);
      case 'pid':
        return entry.pid?.toString() == value;
      case 'tid':
        return entry.tid?.toString() == value;
      case 'level':
        final choices = value
            .split(RegExp(r'[,|]'))
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty);
        final code =
            caseSensitive ? entry.level.code : entry.level.code.toLowerCase();
        final name =
            caseSensitive ? entry.level.name : entry.level.name.toLowerCase();
        return choices.any((choice) => choice == code || choice == name);
      default:
        return (caseSensitive ? entry.searchText : entry.foldedSearchText)
            .contains(value);
    }
  }
}

class _LogcatFilterClause {
  const _LogcatFilterClause({
    required this.field,
    required this.value,
    required this.excluded,
  });

  final String? field;
  final String value;
  final bool excluded;
}

List<String> _tokenizeFilter(String input) {
  final tokens = <String>[];
  var current = StringBuffer();
  String? quote;
  var escaped = false;

  void flush() {
    if (current.isEmpty) return;
    tokens.add(current.toString());
    current = StringBuffer();
  }

  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (escaped) {
      current.write(character);
      escaped = false;
      continue;
    }
    if (quote != null) {
      if (character == r'\') {
        escaped = true;
      } else if (character == quote) {
        quote = null;
      } else {
        current.write(character);
      }
      continue;
    }
    if (character == '"' || character == "'") {
      quote = character;
    } else if (character.trim().isEmpty) {
      flush();
    } else {
      current.write(character);
    }
  }
  if (quote != null) throw const FormatException('Unclosed filter quote.');
  if (escaped) current.write(r'\');
  flush();
  return tokens;
}

class LogcatProvider extends ChangeNotifier {
  LogcatProvider(
    this._service, {
    this.maxRetainedEntries = 30000,
    this.maxPendingLines = 12000,
    this.maxLinesPerFlush = 1200,
    this.flushInterval = const Duration(milliseconds: 80),
  })  : assert(maxRetainedEntries > 0),
        assert(maxPendingLines > 0),
        assert(maxLinesPerFlush > 0),
        _activeFilter = LogcatFilter.compile(
          query: '',
          minLevel: LogLevel.verbose,
          mode: LogcatFilterMode.terms,
          caseSensitive: false,
        );

  final AdbProcessService _service;
  final int maxRetainedEntries;
  final int maxPendingLines;
  final int maxLinesPerFlush;
  final Duration flushInterval;
  final LogcatLineParser _parser = LogcatLineParser();
  final Queue<String> _pendingLines = ListQueue<String>();
  final List<LogEntry> _retainedLogs = <LogEntry>[];
  final List<LogEntry> _visibleLogs = <LogEntry>[];
  late final UnmodifiableListView<LogEntry> _visibleView =
      UnmodifiableListView<LogEntry>(_visibleLogs);

  String? _trackingSerial;
  StreamSubscription<String>? _subscription;
  Timer? _flushTimer;
  Timer? _restartTimer;
  int _captureGeneration = 0;
  int _nextSequence = 1;
  int _droppedSinceFlush = 0;
  bool _captureRequested = false;
  bool _disposed = false;
  LogcatFilter _activeFilter;

  bool isRunning = false;
  String filterText = '';
  LogLevel minLevel = LogLevel.verbose;
  LogcatFilterMode filterMode = LogcatFilterMode.terms;
  bool caseSensitive = false;
  String? filterError;
  String? lastError;
  int logsRevision = 0;
  int filterRevision = 0;
  int totalReceivedLines = 0;
  int droppedPendingLines = 0;

  List<LogEntry> get logs => _visibleView;
  int get retainedCount => _retainedLogs.length;
  int get visibleCount => _visibleLogs.length;
  int get pendingCount => _pendingLines.length;
  bool get captureRequested => _captureRequested;

  void handleDeviceChange(String? newSerial) {
    if (newSerial == _trackingSerial) return;
    final shouldRestart = _captureRequested || isRunning;
    _trackingSerial = newSerial;
    _restartTimer?.cancel();
    _stopCaptureInternal(
      keepRequest: shouldRestart,
      flushPending: false,
      notify: false,
    );
    _clearData(resetCounters: true);

    if (shouldRestart && newSerial != null) {
      _restartTimer = Timer(const Duration(milliseconds: 200), () {
        if (_captureRequested && newSerial == _trackingSerial) startCapture();
      });
    }
    notifyListeners();
  }

  void toggleStart() => _captureRequested ? stopCapture() : startCapture();

  void startCapture() {
    _captureRequested = true;
    _restartTimer?.cancel();
    _stopCaptureInternal(
      keepRequest: true,
      flushPending: true,
      notify: false,
    );
    final serial = _trackingSerial;
    if (serial == null) {
      lastError = 'No target device selected.';
      notifyListeners();
      return;
    }

    final generation = ++_captureGeneration;
    isRunning = true;
    lastError = null;
    notifyListeners();
    _subscription = _service.startLogcat(serial: serial).listen(
      (line) {
        if (generation != _captureGeneration) return;
        _enqueueLine(line);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _captureGeneration || !isRunning) return;
        _finishCapture(generation, error: error);
      },
      onDone: () {
        if (generation != _captureGeneration || !isRunning) return;
        _finishCapture(generation);
      },
      cancelOnError: true,
    );
  }

  void _enqueueLine(String line) {
    totalReceivedLines++;
    if (_pendingLines.length >= maxPendingLines) {
      _pendingLines.removeFirst();
      droppedPendingLines++;
      _droppedSinceFlush++;
    }
    _pendingLines.addLast(line);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushTimer?.isActive == true) return;
    _flushTimer = Timer(flushInterval, _flushPending);
  }

  void _flushPending({bool all = false, bool notify = true}) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pendingLines.isEmpty && _droppedSinceFlush == 0) return;

    final entries = <LogEntry>[];
    if (_droppedSinceFlush > 0) {
      entries.add(LogEntry(
        sequence: _nextSequence++,
        time: '',
        level: LogLevel.warn,
        tag: 'Shirabox',
        msg: 'Dropped $_droppedSinceFlush incoming log lines to keep '
            'capture bounded.',
      ));
      _droppedSinceFlush = 0;
    }

    final limit = all ? _pendingLines.length : maxLinesPerFlush;
    for (var index = 0; index < limit && _pendingLines.isNotEmpty; index++) {
      final entry = _parser.parse(_pendingLines.removeFirst(), _nextSequence);
      if (entry != null) {
        _nextSequence++;
        entries.add(entry);
      }
    }
    final visibleChanged = _appendEntries(entries);
    if (visibleChanged) logsRevision++;
    if (notify) notifyListeners();
    if (_pendingLines.isNotEmpty) _scheduleFlush();
  }

  bool _appendEntries(List<LogEntry> entries) {
    var visibleChanged = false;
    for (final entry in entries) {
      _retainedLogs.add(entry);
      if (_activeFilter.matches(entry)) {
        _visibleLogs.add(entry);
        visibleChanged = true;
      }
    }

    final overflow = _retainedLogs.length - maxRetainedEntries;
    if (overflow <= 0) return visibleChanged;
    _retainedLogs.removeRange(0, overflow);
    final oldestSequence = _retainedLogs.first.sequence;
    var visibleOverflow = 0;
    while (visibleOverflow < _visibleLogs.length &&
        _visibleLogs[visibleOverflow].sequence < oldestSequence) {
      visibleOverflow++;
    }
    if (visibleOverflow > 0) {
      _visibleLogs.removeRange(0, visibleOverflow);
      visibleChanged = true;
    }
    return visibleChanged;
  }

  void _finishCapture(int generation, {Object? error}) {
    if (generation != _captureGeneration) return;
    _flushPending(all: true, notify: false);
    if (error != null) {
      lastError = error.toString();
      final changed = _appendEntries(<LogEntry>[
        LogEntry(
          sequence: _nextSequence++,
          time: '',
          level: LogLevel.error,
          tag: 'Shirabox',
          msg: 'Logcat stopped: $error',
        ),
      ]);
      if (changed) logsRevision++;
    }
    _captureRequested = false;
    isRunning = false;
    _flushTimer?.cancel();
    notifyListeners();
  }

  void setFilter({
    String? query,
    LogLevel? level,
    LogcatFilterMode? mode,
    bool? matchCase,
  }) {
    filterText = query ?? filterText;
    minLevel = level ?? minLevel;
    filterMode = mode ?? filterMode;
    caseSensitive = matchCase ?? caseSensitive;
    filterRevision++;
    try {
      final candidate = LogcatFilter.compile(
        query: filterText,
        minLevel: minLevel,
        mode: filterMode,
        caseSensitive: caseSensitive,
      );
      _activeFilter = candidate;
      filterError = null;
      _rebuildVisibleLogs();
      logsRevision++;
    } on FormatException catch (error) {
      filterError = error.message;
    }
    notifyListeners();
  }

  void updateFilter(String text, LogLevel level) {
    setFilter(query: text, level: level);
  }

  void clearFilterText() => setFilter(query: '');

  void _rebuildVisibleLogs() {
    _visibleLogs
      ..clear()
      ..addAll(_retainedLogs.where(_activeFilter.matches));
  }

  void clear() {
    _clearData(resetCounters: true);
    notifyListeners();
  }

  void _clearData({required bool resetCounters}) {
    _retainedLogs.clear();
    _visibleLogs.clear();
    _pendingLines.clear();
    _droppedSinceFlush = 0;
    if (resetCounters) {
      totalReceivedLines = 0;
      droppedPendingLines = 0;
    }
    logsRevision++;
  }

  Future<String?> export({String? dialogTitle}) async {
    if (_visibleLogs.isEmpty) return null;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle ?? 'Export Logcat JSON',
      fileName: 'logcat_export.json',
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
    );
    if (path == null) return null;
    await exportVisibleTo(path);
    return path;
  }

  Future<void> exportVisibleTo(String path) async {
    final snapshot = List<LogEntry>.of(_visibleLogs, growable: false);
    final sink = File(path).openWrite();
    try {
      sink.writeln('[');
      for (var index = 0; index < snapshot.length; index++) {
        if (index > 0) sink.writeln(',');
        sink.write(jsonEncode(snapshot[index].toJson()));
        if (index % 500 == 499) {
          await sink.flush();
          await Future<void>.delayed(Duration.zero);
        }
      }
      sink.writeln();
      sink.writeln(']');
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  void stopCapture() {
    _restartTimer?.cancel();
    _stopCaptureInternal(
      keepRequest: false,
      flushPending: true,
    );
  }

  void _stopCaptureInternal({
    required bool keepRequest,
    required bool flushPending,
    bool notify = true,
  }) {
    _captureGeneration++;
    _captureRequested = keepRequest;
    if (flushPending) {
      _flushPending(all: true, notify: false);
    } else {
      _flushTimer?.cancel();
      _flushTimer = null;
      _pendingLines.clear();
      _droppedSinceFlush = 0;
    }
    isRunning = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final stopGeneration = _captureGeneration;
    unawaited(_stopService(stopGeneration));
    if (notify) notifyListeners();
  }

  Future<void> _stopService(int generation) async {
    try {
      await _service.stopLogcat();
    } catch (error) {
      if (_disposed || generation != _captureGeneration) return;
      lastError = 'Unable to stop Logcat cleanly: $error';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _restartTimer?.cancel();
    _stopCaptureInternal(
      keepRequest: false,
      flushPending: false,
      notify: false,
    );
    super.dispose();
  }
}
