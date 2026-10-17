import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'adb_core.dart';
import 'owned_process.dart';

// --- 独立的解析函数 (保持不变) ---
List<ProcessInfo> _parseTopOutput(String output) {
  final List<ProcessInfo> processes = [];
  final lines = output.split('\n');
  int cpuIdx = -1;
  int resIdx = -1;
  int nameIdx = -1;
  int userIdx = -1;
  int pidIdx = -1;

  for (var line in lines) {
    line = line.trim();
    if (line.isEmpty) continue;

    // 尋找表頭行
    if (line.contains("PID") &&
        (line.contains("USER") ||
            line.contains("NAME") ||
            line.contains("CMD"))) {
      final headers =
          line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      pidIdx = headers.indexOf("PID");
      userIdx = headers.indexOf("USER");
      cpuIdx = headers.indexWhere((h) => h.contains("CPU"));
      resIdx = headers.indexOf("RES");

      // 名稱列通常是最後一個，或者叫 NAME, CMD, ARGS 等
      nameIdx = headers.indexWhere((h) =>
          h.contains("NAME") ||
          h.contains("CMD") ||
          h.contains("COMMAND") ||
          h.contains("ARGS"));
      if (nameIdx == -1) nameIdx = headers.length - 1;
      continue;
    }

    // 嚴格過濾系統資訊行
    final upperLine = line.toUpperCase();
    if (upperLine.startsWith("TASKS:") ||
        upperLine.startsWith("MEM:") ||
        upperLine.startsWith("SWAP:") ||
        upperLine.startsWith("TOTAL") ||
        upperLine.contains("CPU") && upperLine.contains("%")) {
      continue;
    }

    final parts =
        line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.length < 3) continue;

    // 嚴格校驗：第一列（或者是 pidIdx 指向的列）必須是純數字 PID
    String pidCandidate =
        pidIdx != -1 && pidIdx < parts.length ? parts[pidIdx] : parts[0];
    if (!RegExp(r'^\d+$').hasMatch(pidCandidate)) continue;

    String user = userIdx != -1 && userIdx < parts.length
        ? parts[userIdx]
        : (parts.length > 1 ? parts[1] : "-");
    String cpuRaw = cpuIdx != -1 && cpuIdx < parts.length ? parts[cpuIdx] : "0";
    String res = resIdx != -1 && resIdx < parts.length ? parts[resIdx] : "0M";

    // 智能提取進程名：如果確定了 nameIdx，就從那裡開始合併剩下的所有部分（防止命令中帶空格）
    String name = "";
    if (nameIdx != -1 && nameIdx < parts.length) {
      name = parts.sublist(nameIdx).join(' ');
    } else {
      name = parts.last;
    }

    // 過濾掉看起來像系統標題或時間的名字 (例如 0:00.01)
    if (name.contains(':') && !name.contains('.')) continue; // 可能是時間列
    if (RegExp(r'^\d+[:\.]\d+').hasMatch(name)) {
      // 如果名字是時間，嘗試取它前面或後面的列
      if (parts.last != name) {
        name = parts.last;
      } else if (parts.length > 1) {
        // 解析失敗，這行可能不是進程行
        continue;
      }
    }

    if (name.isEmpty) continue;

    double cpuVal = double.tryParse(cpuRaw.replaceAll('%', '')) ?? 0.0;
    String cpu = "${cpuVal.toStringAsFixed(1)}%";

    processes.add(ProcessInfo(
        pid: pidCandidate,
        name: name,
        user: user,
        cpu: cpu,
        res: res,
        isAndroid: user.startsWith('u0_') ||
            user.contains('shell') ||
            name.contains('.') ||
            !user.contains('root')));
  }

  // 按 CPU 降序排序
  processes.sort((a, b) {
    double cpuA = double.tryParse(a.cpu.replaceAll('%', '')) ?? 0;
    double cpuB = double.tryParse(b.cpu.replaceAll('%', '')) ?? 0;
    return cpuB.compareTo(cpuA);
  });

  return processes;
}

class AdbProcessService {
  final AdbCore _core;
  AdbProcessService(this._core);

  final Set<OwnedCommandHandle> _logcatCommands = <OwnedCommandHandle>{};
  final Set<Future<void>> _logcatLifecycles = <Future<void>>{};
  int _logcatGeneration = 0;

  Stream<String> startLogcat({String? filter, String? serial}) {
    late final StreamController<String> controller;
    OwnedCommandHandle? ownedCommand;
    StreamSubscription<String>? stderrSubscription;
    var cancelled = false;
    final generation = ++_logcatGeneration;
    final previousStop = _stopExistingLogcat();

    controller = StreamController<String>(
      onListen: () {
        late final Future<void> lifecycle;
        lifecycle = (() async {
          try {
            await previousStop;
            if (cancelled || generation != _logcatGeneration) return;

            final command = await _startLogcatCommand(filter, serial);
            ownedCommand = command;
            if (cancelled || generation != _logcatGeneration) {
              await command.cancel();
              return;
            }

            _logcatCommands.add(command);
            stderrSubscription = command.stderr
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())
                .listen((line) {
              if (!controller.isClosed && line.trim().isNotEmpty) {
                controller.add('--- adb: $line');
              }
            });

            await for (final line in command.stdout
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())) {
              if (cancelled || controller.isClosed) break;
              controller.add(line);
            }
            final exit = await command.done;
            await command.stderrDone;
            final ownershipError = exit.releaseError ?? exit.terminationError;
            if (ownershipError != null) {
              throw OwnedProcessException(
                'Logcat process-tree cleanup was not confirmed.',
                cause: ownershipError,
              );
            }
            if (!cancelled &&
                generation == _logcatGeneration &&
                exit.reason == OwnedCommandEndReason.exited &&
                exit.exitCode != 0) {
              throw AdbCommandException(
                'Logcat exited with code ${exit.exitCode}.',
                exitCode: exit.exitCode,
                arguments: command.arguments,
              );
            }
          } catch (e, stackTrace) {
            if (!cancelled && !controller.isClosed) {
              controller.addError(e, stackTrace);
            }
          } finally {
            final command = ownedCommand;
            if (command != null) _logcatCommands.remove(command);
            await stderrSubscription?.cancel();
            if (!controller.isClosed) await controller.close();
          }
        })()
            .whenComplete(() => _logcatLifecycles.remove(lifecycle));
        _logcatLifecycles.add(lifecycle);
      },
      onCancel: () async {
        cancelled = true;
        final command = ownedCommand;
        if (command != null && !command.isCompleted) {
          await command.cancel();
          _logcatCommands.remove(command);
        }
        await stderrSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  Future<OwnedCommandHandle> _startLogcatCommand(
    String? filter,
    String? serial,
  ) {
    final args = <String>[];
    // threadtime keeps PID/TID as machine-readable columns. The UI parser
    // accepts brief/time fallbacks as well, but this is the canonical format.
    args.addAll(['logcat', '-v', 'threadtime']);

    if (filter != null && filter.isNotEmpty) {
      args.addAll(['-s', filter]);
    }

    return _core.startOwnedProcess(args, serial: serial);
  }

  Future<void> stopLogcat() {
    _logcatGeneration++;
    return _stopExistingLogcat();
  }

  Future<void> _stopExistingLogcat() async {
    final lifecycles = _logcatLifecycles.toList(growable: false);
    await _cancelOwnedLogcatCommands();
    await Future.wait(lifecycles);
  }

  Future<void> _cancelOwnedLogcatCommands() async {
    final commands = _logcatCommands.toList(growable: false);
    await Future.wait(commands.map((command) async {
      try {
        if (!command.isCompleted) await command.cancel();
      } finally {
        _logcatCommands.remove(command);
      }
    }));
  }

  Future<void> clearLogcat() async {
    await _core.runSafe(['logcat', '-c']);
  }

  Future<List<ProcessInfo>> getProcessList() async {
    try {
      // 增加採樣時間並獲取 2 幀數據以解決 0% 問題
      final result = await _core.runText(
        ['shell', 'top', '-b', '-n', '2', '-d', '1'],
        timeout: const Duration(seconds: 10),
      );
      if (result.isEmpty) return [];

      // 通過尋找最後一個 PID USER 標題行來獲取最後一次採樣的數據
      int lastHeaderIdx = result
          .lastIndexOf(RegExp(r'PID\s+USER|PID\s+PR|PID\s+NAME|PID\s+CMD'));
      if (lastHeaderIdx == -1) return [];

      // 提取最後一個採樣區塊
      String targetOutput = result.substring(lastHeaderIdx);
      return await compute(_parseTopOutput, targetOutput);
    } catch (e) {
      return [];
    }
  }

  Future<String?> killProcess(String pid) async {
    if (!RegExp(r'^\d+$').hasMatch(pid)) return 'Invalid process ID.';
    try {
      await _core.runSafe(['shell', 'kill', '-9', pid]);
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}

class ProcessInfo {
  final String pid;
  final String name;
  final String user;
  final String cpu;
  final String res;
  final bool isAndroid;

  ProcessInfo(
      {required this.pid,
      required this.name,
      required this.user,
      required this.cpu,
      required this.res,
      required this.isAndroid});
}
