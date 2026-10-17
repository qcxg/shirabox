import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import '../services/adb_core.dart';
import '../services/adb_file.dart';
import '../services/adb_process.dart';
import '../services/agent_client.dart';

// --- Main State Class ---
class AppState extends ChangeNotifier {
  final AdbCore _core;
  late final AdbFileService _files;
  late final AdbProcessService _processes;
  late final AgentClient _agent;
  bool _isDisposed = false;
  late final Future<void> _initialization;
  Future<void> get initialized => _initialization;

  // 公开 Getters
  AdbCore get adb => _core;
  AdbFileService get files => _files;
  AdbProcessService get processes => _processes;
  bool get isAdbValid => _core.isValid;
  bool get isAdbFallback => _core.isFallback;
  String appVersion = "0.9.0"; // 默認值

  AppState([AdbCore? core]) : _core = core ?? AdbCore() {
    _initValues();
    _initialization = _loadSettings();
    _initVersion();
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }

  void _initValues() {
    _files = AdbFileService(_core);
    _processes = AdbProcessService(_core);
    _agent = AgentClient(_core);
  }

  Future<void> _initVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = "${info.version}+${info.buildNumber}";
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _isDisposed = true;
    _fetchSessionId++;
    unawaited(_deviceTrackSub?.cancel());
    unawaited(_cancelActiveAppFetch());
    unawaited(_logStreamCtrl.close());
    unawaited(_agent.stop());
    unawaited(_core.disposeRuntime());
    super.dispose();
  }

  // ============================================
  // 1. Device Logic (设备管理 - 核心修改区域)
  // ============================================
  List<String> devices = [];
  // 【新增】设备型号缓存 (SN -> Model)
  final Map<String, String> _deviceModelCache = {};
  // 【新增】無線鏈接歷史
  List<String> connectHistory = [];
  final Map<String, String> historyModels = {};

  String? currentDevice;
  bool isConnected = false;
  Map<String, String> deviceDetail = {};
  StreamSubscription? _deviceTrackSub;
  int _deviceTrackingGeneration = 0;
  Future<void>? _systemRefreshInFlight;
  int? _systemRefreshSessionId;

  int get deviceSessionEpoch => _core.targetSnapshot.sessionEpoch;

  bool isDeviceSessionActive(String serial, int epoch) =>
      _isDeviceSessionCurrent(serial, epoch);

  // 【新增】获取显示名称 (供 UI 使用)
  String getDeviceName(String serial) {
    return _deviceModelCache[serial] ?? serial;
  }

  Future<void> checkDevices() async {
    await _initialization;
    await _startDeviceTracking();
  }

  Future<void> retryAdbConnection() async {
    await _initialization;
    if (_isDisposed) return;
    await _core.checkAvailability();
    notifyListeners();
    await _startDeviceTracking();
  }

  Future<void> _startDeviceTracking() async {
    final generation = ++_deviceTrackingGeneration;
    final previous = _deviceTrackSub;
    _deviceTrackSub = null;
    await previous?.cancel();
    if (_isDisposed || generation != _deviceTrackingGeneration) return;
    _deviceTrackSub = _core.trackDevices(onDiagnostic: (message) {
      if (!_isDisposed && generation == _deviceTrackingGeneration) {
        addLog(message);
      }
    }).listen((newDevices) {
      if (_isDisposed || generation != _deviceTrackingGeneration) return;
      // 这里的逻辑：只要列表变动，或者缓存里没有新设备的型号，都触发更新
      if (!listEquals(newDevices, devices) ||
          newDevices.any((s) => !_deviceModelCache.containsKey(s))) {
        devices = newDevices;

        // 1. 异步获取新设备的型号
        for (var serial in devices) {
          if (!_deviceModelCache.containsKey(serial)) {
            // 先占位，防止 UI 闪烁
            _deviceModelCache[serial] = serial;
            // 异步调用底层获取型号
            _core.getDeviceModel(serial).then((model) {
              if (_isDisposed || !devices.contains(serial)) return;
              if (model != serial) {
                _deviceModelCache[serial] = model;
                // 获取到型号后，刷新 UI (侧边栏名字变了)
                notifyListeners();
                // 如果是当前设备，顺便刷新标题
                if (serial == currentDevice) _updateTitle();
              }
            });
          }
        }

        // 2. 清理已拔出设备的缓存
        _deviceModelCache.removeWhere((key, _) => !devices.contains(key));

        // 3. 处理当前连接状态
        if (devices.isNotEmpty) {
          // 自动重连或保持当前设备
          if (currentDevice == null || !devices.contains(currentDevice)) {
            switchDevice(devices.first);
          } else {
            _updateTitle();
          }
        } else {
          // 断开连接
          if (isConnected) {
            _invalidateAppFetchState(clearCache: true);
            isConnected = false;
            currentDevice = null;
            _core.setTargetDevice(null);
            addLog("Device Disconnected");
            _updateTitle();
          }
        }
      }
      // Even an empty first snapshot updates ADB availability in the UI.
      notifyListeners();
    });
  }

  void switchDevice(String serial) {
    if (!devices.contains(serial)) return;

    _invalidateAppFetchState(clearCache: true);
    currentDevice = serial;
    isConnected = true;
    _core.setTargetDevice(serial); // 锁定底层 Core

    addLog("Switched to: ${getDeviceName(serial)}");

    // 重置状态
    deviceDetail = {};
    _prevTotal = 0;
    _prevIdle = 0;

    // 刷新新设备信息
    _refreshAllInfo();
    notifyListeners();
  }

  // --- 無線鏈接邏輯 ---
  Future<void> wirelessConnect(String ipPort) async {
    await _initialization;
    if (_isDisposed) return;
    ipPort = ipPort.trim();
    addLog("Connecting to $ipPort...");
    final res = await _core.connect(ipPort);
    addLog(res);

    if (res.contains("connected to")) {
      // 成功後加入歷史並置頂
      connectHistory.remove(ipPort);
      connectHistory.insert(0, ipPort);
      if (connectHistory.length > 20) connectHistory.removeLast();

      // 嘗試獲取型號並更新
      unawaited(_updateHistoryModel(ipPort));

      _saveSettings();
      await checkDevices();
    }
    notifyListeners();
  }

  Future<void> _updateHistoryModel(String ipPort) async {
    // 等待設備在 adb devices 中出現 (最多 3 秒)
    for (int i = 0; i < 6; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (_isDisposed) return;
      final List<String> currentDevices;
      try {
        currentDevices = await _core.listDevices();
      } catch (_) {
        continue;
      }
      if (currentDevices.contains(ipPort)) {
        final model = await _core.getDeviceModel(ipPort);
        if (_isDisposed) return;
        if (model != ipPort) {
          historyModels[ipPort] = model;
          _saveSettings();
          notifyListeners();
          return;
        }
      }
    }
  }

  Future<void> wirelessDisconnect(String ipPort) async {
    await _initialization;
    if (_isDisposed) return;
    addLog("Disconnecting $ipPort...");
    final res = await _core.disconnect(ipPort);
    addLog(res);
    await checkDevices();
    notifyListeners();
  }

  void removeHistory(String ipPort) {
    connectHistory.remove(ipPort);
    historyModels.remove(ipPort);
    _saveSettings();
    notifyListeners();
  }

  void _updateTitle() async {
    String title = "Shirabox";
    if (isConnected && currentDevice != null) {
      // 使用缓存的型号
      String info = getDeviceName(currentDevice!);
      title = "Shirabox - $info";
    }
    await windowManager.setTitle(title);
  }

  void _refreshAllInfo() {
    final serial = currentDevice;
    if (!isConnected || serial == null) return;
    final sessionId = deviceSessionEpoch;
    unawaited(_loadAllInfo(serial, sessionId));
  }

  Future<void> _loadAllInfo(String serial, int sessionId) async {
    final details = await _core.getDeviceDetails();
    if (!_isDeviceSessionCurrent(serial, sessionId)) return;

    deviceDetail = details;
    await refreshSystemInfoOnly();
    if (!_isDeviceSessionCurrent(serial, sessionId)) return;

    _updateTitle();
    notifyListeners();
  }

  // ============================================
  // 2. System Monitor (资源监控)
  // ============================================
  Map<String, dynamic> ramInfo = {'ratio': 0.0, 'text': '- / -'};
  Map<String, dynamic> storageInfo = {'ratio': 0.0, 'text': '- / -'};
  Map<String, dynamic> cpuInfo = {'ratio': 0.0, 'text': '0%'};
  String kernelVersion = "-";
  int _prevTotal = 0;
  int _prevIdle = 0;

  Future<void> refreshSystemInfoOnly() {
    final serial = currentDevice;
    if (!isConnected || serial == null || _isDisposed) {
      return Future<void>.value();
    }
    final sessionId = deviceSessionEpoch;

    final existing = _systemRefreshInFlight;
    if (existing != null) {
      final existingSessionId = _systemRefreshSessionId;
      if (existingSessionId == sessionId) return existing;
      return _refreshSystemInfoAfter(existing, serial, sessionId);
    }

    late final Future<void> operation;
    operation = _performSystemRefresh(serial, sessionId).whenComplete(() {
      if (identical(_systemRefreshInFlight, operation)) {
        _systemRefreshInFlight = null;
        _systemRefreshSessionId = null;
      }
    });
    _systemRefreshInFlight = operation;
    _systemRefreshSessionId = sessionId;
    return operation;
  }

  Future<void> _refreshSystemInfoAfter(
      Future<void> existing, String serial, int sessionId) async {
    await existing;
    if (_isDeviceSessionCurrent(serial, sessionId)) {
      await refreshSystemInfoOnly();
    }
  }

  Future<void> _performSystemRefresh(String serial, int sessionId) async {
    try {
      final sys = await _core.getSystemStatus();
      if (!_isDeviceSessionCurrent(serial, sessionId) || sys.isEmpty) return;

      ramInfo = sys['ram'];
      storageInfo = sys['storage'];
      kernelVersion = sys['kernel'] ?? '-';
      _calcCpu(sys['cpu_stat']);
      notifyListeners();
    } catch (_) {}
  }

  bool _isDeviceSessionCurrent(String serial, int sessionId) {
    return !_isDisposed &&
        isConnected &&
        currentDevice == serial &&
        deviceSessionEpoch == sessionId;
  }

  void _calcCpu(String? rawStat) {
    if (rawStat == null) return;
    final parts = rawStat
        .split('\n')
        .firstWhere((l) => l.startsWith('cpu '), orElse: () => "")
        .split(RegExp(r'\s+'));
    if (parts.length < 5) return;
    int total = 0;
    for (int i = 1; i <= 4; i++) {
      total += (int.tryParse(parts[i]) ?? 0);
    }
    int idle = int.tryParse(parts[4]) ?? 0;
    if (_prevTotal != 0) {
      int totalDelta = total - _prevTotal;
      int idleDelta = idle - _prevIdle;
      if (totalDelta > 0) {
        double usage = (totalDelta - idleDelta) / totalDelta;
        cpuInfo = {'ratio': usage, 'text': "${(usage * 100).toInt()}%"};
      }
    }
    _prevTotal = total;
    _prevIdle = idle;
  }

  // ============================================
  // 3. App Logic (应用管理)
  // ============================================
  List<AppData> appList = [];
  Map<String, Uint8List> appIconBytesCache = {};
  bool isSelectionMode = false;
  bool isLoadingApps = false;
  String? _iconCacheDeviceId;
  StreamIterator<String>? _fetchIterator;
  int _fetchSessionId = 0;
  int? _iconPrefetchSessionId;
  bool launchWithMirror = false; // 是否在啟動應用時開啟投屏

  // ... 其他代码 ...

  Future<void> fetchApps() async {
    final deviceId = currentDevice;
    if (!isConnected || deviceId == null || _isDisposed) return;

    _fetchSessionId++;
    final int mySessionId = _fetchSessionId;

    // Session guards make the old stream unable to commit. Do not block a new
    // device behind cancellation of an obsolete startup/JAR push.
    unawaited(_cancelActiveAppFetch());
    if (!_isAppFetchCurrent(mySessionId, deviceId)) return;
    _iconPrefetchSessionId = null;

    if (_iconCacheDeviceId != deviceId) {
      appIconBytesCache.clear();
      _iconCacheDeviceId = deviceId;
    }

    appList.clear();
    isSelectionMode = false;
    isLoadingApps = true;
    notifyListeners();

    addLog("Fetching app list...");
    final Set<String> seen = {};
    final rawBuffer = <String>[];
    final iterator =
        StreamIterator<String>(_agent.fetchAppListRawStream(deviceId));
    _fetchIterator = iterator;

    try {
      while (await iterator.moveNext()) {
        if (!_isAppFetchCurrent(mySessionId, deviceId)) return;
        final line = iterator.current;
        final agentError = _agentErrorMessage(line);
        if (agentError != null) {
          throw AdbCommandException(agentError);
        }
        rawBuffer.add(line);

        if (rawBuffer.length >= 70) {
          final batchData = List<String>.from(rawBuffer);
          rawBuffer.clear();
          final newApps = await compute(_parseJsonBatch, batchData);
          if (!_isAppFetchCurrent(mySessionId, deviceId)) return;
          _addApps(newApps, seen);
          notifyListeners();
        }
      }

      if (!_isAppFetchCurrent(mySessionId, deviceId)) return;
      if (rawBuffer.isNotEmpty) {
        final tailData = List<String>.from(rawBuffer);
        final newApps = await compute(_parseJsonBatch, tailData);
        if (!_isAppFetchCurrent(mySessionId, deviceId)) return;
        _addApps(newApps, seen);
      }

      appList.sort((a, b) {
        if (a.isSystem != b.isSystem) return a.isSystem ? 1 : -1;
        return a.displayName.compareTo(b.displayName);
      });

      isLoadingApps = false;
      notifyListeners();
      addLog("Apps loaded: ${appList.length}");
      unawaited(_startIconPrefetch(mySessionId, deviceId));
    } catch (e) {
      if (_isAppFetchCurrent(mySessionId, deviceId)) {
        appList.clear();
        isLoadingApps = false;
        addLog("Error: $e");
        notifyListeners();
      }
    } finally {
      if (identical(_fetchIterator, iterator)) {
        _fetchIterator = null;
        try {
          await iterator.cancel();
        } catch (_) {}
      }
    }
  }

  Future<void> _cancelActiveAppFetch() async {
    final iterator = _fetchIterator;
    _fetchIterator = null;
    if (iterator != null) {
      try {
        await iterator.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  void _invalidateAppFetchState({required bool clearCache}) {
    _fetchSessionId++;
    unawaited(_cancelActiveAppFetch());
    _iconPrefetchSessionId = null;
    isLoadingApps = false;
    isSelectionMode = false;
    if (clearCache) {
      appList.clear();
      appIconBytesCache.clear();
      _iconCacheDeviceId = null;
    }
  }

  bool _isAppFetchCurrent(int sessionId, String deviceId) {
    return !_isDisposed &&
        isConnected &&
        currentDevice == deviceId &&
        _fetchSessionId == sessionId;
  }

  // ... 其他代码 ...

  void _addApps(List<AppData> newApps, Set<String> seen) {
    for (var app in newApps) {
      if (!seen.contains(app.packageName)) {
        appList.add(app);
        seen.add(app.packageName);
      }
    }
  }

  Future<void> _startIconPrefetch(int sessionId, String deviceId) async {
    if (!_isAppFetchCurrent(sessionId, deviceId) ||
        _iconPrefetchSessionId == sessionId) {
      return;
    }
    _iconPrefetchSessionId = sessionId;
    final targets = appList
        .where((app) => !appIconBytesCache.containsKey(app.packageName))
        .toList();

    try {
      for (int i = 0; i < targets.length; i += 6) {
        if (!_isAppFetchCurrent(sessionId, deviceId)) return;
        final end = (i + 6 < targets.length) ? i + 6 : targets.length;
        final results = await Future.wait(
          targets.sublist(i, end).map((app) async {
            try {
              final bytes = await _agent.fetchIcon(
                app.packageName,
                serial: deviceId,
              );
              return MapEntry<String, Uint8List?>(app.packageName, bytes);
            } catch (_) {
              return MapEntry<String, Uint8List?>(app.packageName, null);
            }
          }),
        );

        if (!_isAppFetchCurrent(sessionId, deviceId)) return;
        for (final result in results) {
          final bytes = result.value;
          if (bytes != null && bytes.isNotEmpty) {
            appIconBytesCache[result.key] = bytes;
          }
        }
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 1));
      }
    } finally {
      if (_iconPrefetchSessionId == sessionId) {
        _iconPrefetchSessionId = null;
      }
    }
  }

  Uint8List? getCachedIcon(String pkg) => appIconBytesCache[pkg];

  void toggleSelectionMode(bool val) {
    isSelectionMode = val;
    if (!val)
      // ignore: curly_braces_in_flow_control_structures
      for (var a in appList) {
        a.isSelected = false;
      }
    notifyListeners();
  }

  void toggleAppSelection(AppData app) {
    app.isSelected = !app.isSelected;
    notifyListeners();
  }

  void selectAll(bool val) {
    for (var a in appList) {
      a.isSelected = val;
    }
    notifyListeners();
  }

  Future<void> extractSelectedApps(String dir) async {
    final selected = appList.where((a) => a.isSelected).toList();
    if (selected.isEmpty) return;
    final serial = currentDevice;
    if (serial == null) return;
    addLog("Extracting ${selected.length} apps...");
    int success = 0;
    for (var app in selected) {
      try {
        await _files.extractApp(
          app.packageName,
          dir,
          app.splitPaths,
          app.path,
          serial: serial,
        );
        success++;
      } catch (e) {
        addLog("Failed ${app.packageName}: $e");
      }
    }
    addLog("Done: $success/${selected.length}");
    toggleSelectionMode(false);
  }

  Future<void> launchApp(String packageName) async {
    try {
      addLog("Launching: $packageName");
      await _core.runSafe([
        'shell',
        'monkey',
        '-p',
        packageName,
        '-c',
        'android.intent.category.LAUNCHER',
        '1',
      ]);
    } catch (e) {
      addLog("Launch Failed: $e");
    }
  }

  void setLaunchWithMirror(bool val) {
    launchWithMirror = val;
    _saveSettings();
    notifyListeners();
  }

  Future<void> toggleAppEnable(AppData app) async {
    try {
      final args = !app.isEnabled
          ? ['shell', 'pm', 'enable', app.packageName]
          : [
              'shell',
              'pm',
              'disable-user',
              '--user',
              '0',
              app.packageName,
            ];
      await _core.runSafe(args);
      app.isEnabled = !app.isEnabled;
      notifyListeners();
    } catch (e) {
      addLog("Op Failed: $e");
    }
  }

  // ============================================
  // 4. Settings & Config
  // ============================================
  Locale? _locale;
  Color seedColor = Colors.blue;
  String customAdbPath = "";
  bool showQuickBoot = true;
  List<QuickCommand> quickCommands = [
    QuickCommand(
        name: "Shizuku",
        command: "sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh"),
    QuickCommand(
        name: "Scene",
        command: "sh /sdcard/Android/data/com.omarea.vtools/files/up.sh"),
  ];

  Locale? get locale => _locale;

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final langCode = prefs.getString('language_code');
      if (langCode != null) {
        if (langCode.contains('_')) {
          final parts = langCode.split('_');
          if (parts.length == 2) _locale = Locale(parts[0], parts[1]);
        } else {
          _locale = Locale(langCode);
        }
      }
      final colorValue = prefs.getInt('theme_color');
      if (colorValue != null) seedColor = Color(colorValue);
      customAdbPath = prefs.getString('adb_path') ?? "";
      if (customAdbPath.isNotEmpty) _core.setAdbPath(customAdbPath);
      showQuickBoot = prefs.getBool('show_quick_boot') ?? true;
      launchWithMirror = prefs.getBool('launch_with_mirror') ?? false;
      final cmdsString = prefs.getString('quick_commands');
      if (cmdsString != null) {
        List<dynamic> jsonList = jsonDecode(cmdsString);
        quickCommands = jsonList.map((e) => QuickCommand.fromJson(e)).toList();
      }
      connectHistory = prefs.getStringList('connect_history') ?? [];
      final historyModelsJson = prefs.getString('history_models_metadata');
      if (historyModelsJson != null) {
        try {
          final Map<String, dynamic> decoded = jsonDecode(historyModelsJson);
          decoded.forEach((key, value) {
            historyModels[key] = value.toString();
          });
        } catch (_) {}
      }
    } catch (error) {
      addLog('Settings could not be loaded: $error');
    } finally {
      // Resolve the saved executable before opening the first device tracker.
      await _startDeviceTracking();
      notifyListeners();
    }
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    if (_locale != null) {
      p.setString('language_code', _locale!.toString());
    } else {
      p.remove('language_code');
    }
    p.setInt('theme_color', seedColor.toARGB32());
    p.setString('adb_path', customAdbPath);
    p.setBool('show_quick_boot', showQuickBoot);
    p.setBool('launch_with_mirror', launchWithMirror);
    p.setString('quick_commands',
        jsonEncode(quickCommands.map((e) => e.toJson()).toList()));
    p.setStringList('connect_history', connectHistory);
    p.setString('history_models_metadata', jsonEncode(historyModels));
  }

  void changeLanguage(Locale? locale) {
    _locale = locale;
    _saveSettings();
    notifyListeners();
  }

  void updateThemeColor(Color c) {
    seedColor = c;
    _saveSettings();
    notifyListeners();
  }

  void updateSettings({Color? color, String? adbPath, bool? showQuick}) {
    if (color != null) seedColor = color;
    if (adbPath != null) {
      customAdbPath = adbPath;
      _core.setAdbPath(adbPath);
      unawaited(checkDevices());
    }
    if (showQuick != null) showQuickBoot = showQuick;
    _saveSettings();
    notifyListeners();
  }

  void updateQuickCommands(List<QuickCommand> cmds) {
    quickCommands = cmds;
    _saveSettings();
    notifyListeners();
  }

  Future<void> runQuickCommand(QuickCommand cmd) async {
    addLog("Run: ${cmd.name}");
    try {
      addLog(await _core.runScript(cmd.command));
    } catch (e) {
      addLog('Command failed: $e');
    }
  }

  // ============================================
  // 5. Logging
  // ============================================
  String logText = "System Ready...";
  final StreamController<void> _logStreamCtrl = StreamController.broadcast();
  Stream<void> get onLogAdded => _logStreamCtrl.stream;

  void addLog(String text) {
    if (_isDisposed) return;
    String time = DateTime.now().toIso8601String().substring(11, 19);
    logText = "[$time] $text\n$logText";
    if (logText.length > 50000) logText = logText.substring(0, 50000);
    _logStreamCtrl.add(null);
    notifyListeners();
  }
}

// ============================================
// Data Classes
// ============================================
class QuickCommand {
  String name;
  String command;
  String checkPackage;
  QuickCommand(
      {required this.name, required this.command, this.checkPackage = ''});
  Map<String, dynamic> toJson() =>
      {'name': name, 'command': command, 'checkPackage': checkPackage};
  factory QuickCommand.fromJson(Map<String, dynamic> json) => QuickCommand(
      name: json['name'],
      command: json['command'],
      checkPackage: json['checkPackage'] ?? '');
}

class AppData {
  final String packageName;
  final String path;
  final List<String> splitPaths;
  String displayName;
  bool isSystem;
  bool isEnabled;
  bool isSelected;

  AppData({
    required this.packageName,
    required this.path,
    this.splitPaths = const [],
    this.displayName = "",
    this.isSystem = false,
    this.isEnabled = true,
    this.isSelected = false,
  });
  bool get isSplit => splitPaths.isNotEmpty;
}

List<AppData> _parseJsonBatch(List<String> lines) {
  final List<AppData> results = [];
  for (final line in lines) {
    if (line.isEmpty) continue;
    try {
      final item = jsonDecode(line);
      final packageName = item['pkg']?.toString() ?? '';
      if (packageName.isEmpty || packageName == 'error') continue;
      results.add(AppData(
        packageName: packageName,
        path: item['path'] ?? '',
        splitPaths: (item['splits'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        displayName: item['name'] ?? '',
        isSystem: item['sys'] ?? false,
        isEnabled: item['en'] ?? true,
        isSelected: false,
      ));
    } catch (_) {}
  }
  return results;
}

String? _agentErrorMessage(String line) {
  if (!line.contains('"pkg":"error"')) return null;
  try {
    final item = jsonDecode(line);
    if (item is Map<String, dynamic> && item['pkg'] == 'error') {
      return item['name']?.toString() ?? 'Android helper failed.';
    }
  } catch (_) {}
  return null;
}
