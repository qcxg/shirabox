import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_state.dart';
import '../services/owned_process.dart';

class ScrcpyProvider extends ChangeNotifier {
  final AppState _appState;

  // 用于检测设备变化的缓存
  String? _lastSerial;

  ScrcpyProvider(this._appState) {
    _lastSerial = _appState.currentDevice;
    _loadSettings();
  }

  // --- 状态参数 ---
  int maxSize = 0;
  int bitRate = 8;
  int maxFps = 60;
  bool stayAwake = true;
  bool turnScreenOff = false;
  bool showTouches = false;
  bool alwaysOnTop = false;
  bool noAudio = false;
  bool keyboardNav = false;
  String videoCodec = 'h264';

  TextEditingController cmdPreviewCtrl = TextEditingController();

  String get _bundledVbsPath {
    String exeDir = File(Platform.resolvedExecutable).parent.path;
    return p.join(exeDir, 'data', 'scrcpy', 'scrcpy-noconsole.vbs');
  }

  // 运行状态
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  // 跟踪每个序列号对应的 VBS 进程
  final Map<String, OwnedCommandHandle> _runningProcesses = {};

  // --- 快捷按钮管理 ---
  List<QuickActionItem> quickActions = [];

  // 默认按钮列表 (去掉了低频使用的)
  final List<QuickActionItem> _defaultActions = [
    QuickActionItem(
        id: 'vol_down',
        icon: Icons.volume_down,
        label: 'Vol-',
        cmd: 'input keyevent 25'),
    QuickActionItem(
        id: 'vol_up',
        icon: Icons.volume_up,
        label: 'Vol+',
        cmd: 'input keyevent 24'),
    QuickActionItem(
        id: 'back',
        icon: Icons.arrow_back,
        label: 'Back',
        cmd: 'input keyevent 4'),
    QuickActionItem(
        id: 'home', icon: Icons.home, label: 'Home', cmd: 'input keyevent 3'),
    QuickActionItem(
        id: 'recent',
        icon: Icons.apps,
        label: 'Recent',
        cmd: 'input keyevent 187'),
    QuickActionItem(
        id: 'shot',
        icon: Icons.camera_alt,
        label: 'Shot',
        cmd: 'input keyevent 120'),
    QuickActionItem(
        id: 'power',
        icon: Icons.power_settings_new,
        label: 'Power',
        cmd: 'input keyevent 26',
        longCmd: 'input keyevent --longpress 26'),
    // 补充一些实用的
    QuickActionItem(
        id: 'menu', icon: Icons.menu, label: 'Menu', cmd: 'input keyevent 82'),
    QuickActionItem(
        id: 'notification',
        icon: Icons.notifications,
        label: 'Notif',
        cmd: 'cmd statusbar expand-notifications'),
  ];

  // 重新排序方法
  void reorderActions(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final item = quickActions.removeAt(oldIndex);
    quickActions.insert(newIndex, item);
    _saveActionOrder();
    notifyListeners();
  }

  // 保存顺序
  Future<void> _saveActionOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final orderList = quickActions.map((e) => e.id).toList();
    prefs.setStringList('sc_action_order', orderList);
  }

  // 加载顺序
  Future<void> _loadActionOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final savedOrder = prefs.getStringList('sc_action_order');

    if (savedOrder != null && savedOrder.isNotEmpty) {
      quickActions = [];
      for (var id in savedOrder) {
        try {
          var item = _defaultActions.firstWhere((e) => e.id == id);
          quickActions.add(item);
        } catch (_) {}
      }
      // 补充新增加的默认项
      for (var item in _defaultActions) {
        if (!quickActions.any((e) => e.id == item.id)) {
          quickActions.add(item);
        }
      }
    } else {
      quickActions = List.from(_defaultActions);
    }
  }

  // --- 核心逻辑: 设备联动 ---
  // 由 MainLayout 的 ProxyProvider 调用
  void handleDeviceChange() {
    // 如果设备变了，或者之前没设备现在有了，就需要刷新预览命令
    if (_appState.currentDevice != _lastSerial) {
      _lastSerial = _appState.currentDevice;
      _updatePreview();
      // 这里不需要 notifyListeners，因为 _updatePreview 可能会做，或者 UI 会随 AppState 刷新
    }
  }

  // --- 启动逻辑 ---
  Future<void> startScrcpy() async {
    final serial = _appState.currentDevice;
    if (serial == null) return;

    // 如果該設備已經在投屏中，則不重複打開窗口
    if (_runningProcesses.containsKey(serial)) {
      _appState.addLog(
          "Scrcpy already running for $serial, skipping window launch.");
      // 確保狀態同步
      if (!_isRunning) {
        _isRunning = true;
        notifyListeners();
      }
      return;
    }

    final vbsPath = _bundledVbsPath;
    if (!File(vbsPath).existsSync()) {
      _appState.addLog("Error: vbs missing at $vbsPath");
      return;
    }

    try {
      final scrcpyArgs = _buildArgs(serial: serial);
      _appState.addLog("Starting Scrcpy for $serial...");

      // 使用 VBS 啟動 (VBS 已改為 True 等待模式)
      final process = await _appState.adb.startOwnedExecutable(
        'wscript',
        [vbsPath, ...scrcpyArgs],
        workingDirectory: File(vbsPath).parent.path,
        serial: serial,
      );

      _runningProcesses[serial] = process;
      _isRunning = true;
      notifyListeners();

      // 當該設備的 VBS (及其內部的 scrcpy) 結束時
      process.done.then((_) {
        if (!identical(_runningProcesses[serial], process)) return;
        _runningProcesses.remove(serial);
        _appState.addLog("Scrcpy for $serial exited.");

        // 檢查是否還有其他設備在投屏，或者系統中是否還有殘留進程
        bool stillAlive = _runningProcesses.isNotEmpty;
        if (stillAlive != _isRunning) {
          _isRunning = stillAlive;
          notifyListeners();
        }
      });
    } catch (e) {
      _appState.addLog("Start Failed ($serial): $e");
      if (_runningProcesses.isEmpty) {
        _isRunning = false;
        notifyListeners();
      }
    }
  }

  // --- 停止逻辑 ---
  Future<void> stopScrcpy() async {
    _appState.addLog("Stopping Shirabox Scrcpy processes...");
    final processes = _runningProcesses.values.toList(growable: false);
    _runningProcesses.clear();
    if (_isRunning) {
      _isRunning = false;
      notifyListeners();
    }
    await Future.wait<void>(processes.map((process) async {
      try {
        if (!process.isCompleted) await process.cancel();
      } catch (error) {
        _appState.addLog("Scrcpy stop failed: $error");
      }
    }));
  }

  @override
  void dispose() {
    final processes = _runningProcesses.values.toList(growable: false);
    _runningProcesses.clear();
    for (final process in processes) {
      unawaited(() async {
        try {
          await process.cancel();
        } catch (_) {}
      }());
    }
    cmdPreviewCtrl.dispose();
    super.dispose();
  }

  // --- 参数存取 ---
  void _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    maxSize = prefs.getInt('sc_max_size') ?? 0;
    bitRate = prefs.getInt('sc_bit_rate') ?? 8;
    maxFps = prefs.getInt('sc_fps') ?? 0;
    stayAwake = prefs.getBool('sc_stay_awake') ?? true;
    turnScreenOff = prefs.getBool('sc_screen_off') ?? false;
    showTouches = prefs.getBool('sc_show_touches') ?? false;
    alwaysOnTop = prefs.getBool('sc_always_top') ?? false;
    noAudio = prefs.getBool('sc_no_audio') ?? false;
    keyboardNav = prefs.getBool('sc_key_nav') ?? false;
    videoCodec = prefs.getString('sc_codec') ?? 'h264';

    await _loadActionOrder();

    _updatePreview();
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setInt('sc_max_size', maxSize);
    prefs.setInt('sc_bit_rate', bitRate);
    prefs.setInt('sc_fps', maxFps);
    prefs.setBool('sc_stay_awake', stayAwake);
    prefs.setBool('sc_screen_off', turnScreenOff);
    prefs.setBool('sc_show_touches', showTouches);
    prefs.setBool('sc_always_top', alwaysOnTop);
    prefs.setBool('sc_no_audio', noAudio);
    prefs.setBool('sc_key_nav', keyboardNav);
    prefs.setString('sc_codec', videoCodec);
  }

  void _updatePreview() {
    final args = _buildArgs();
    cmdPreviewCtrl.text = "scrcpy ${args.join(' ')}";
  }

  List<String> _buildArgs({String? serial}) {
    List<String> args = [];

    // 【核心】注入当前设备 Serial
    final targetSerial = serial ?? _appState.currentDevice;
    if (targetSerial != null) {
      args.add('-s');
      args.add(targetSerial);
    }

    if (videoCodec != 'h264') args.add('--video-codec=$videoCodec');

    if (maxSize > 0) {
      args.add('--max-size');
      args.add(maxSize.toString());
    }

    if (bitRate != 8) {
      args.add('--video-bit-rate');
      args.add('${bitRate}M');
    }

    if (maxFps > 0) {
      args.add('--max-fps');
      args.add(maxFps.toString());
    }

    if (stayAwake) args.add('--stay-awake');
    if (turnScreenOff) args.add('--turn-screen-off');
    if (showTouches) args.add('--show-touches');
    if (alwaysOnTop) args.add('--always-on-top');
    if (noAudio) args.add('--no-audio');
    if (keyboardNav) args.add('--keyboard=uhid');

    return args;
  }

  void updateParam({
    int? newMaxSize,
    int? newBitRate,
    int? newFps,
    bool? newStayAwake,
    bool? newTurnScreenOff,
    bool? newShowTouches,
    bool? newAlwaysOnTop,
    bool? newNoAudio,
    bool? newKeyboardNav,
    String? newCodec,
  }) {
    if (newMaxSize != null) maxSize = newMaxSize;
    if (newBitRate != null) bitRate = newBitRate;
    if (newFps != null) maxFps = newFps;
    if (newStayAwake != null) stayAwake = newStayAwake;
    if (newTurnScreenOff != null) turnScreenOff = newTurnScreenOff;
    if (newShowTouches != null) showTouches = newShowTouches;
    if (newAlwaysOnTop != null) alwaysOnTop = newAlwaysOnTop;
    if (newNoAudio != null) noAudio = newNoAudio;
    if (newKeyboardNav != null) keyboardNav = newKeyboardNav;
    if (newCodec != null) videoCodec = newCodec;

    _saveSettings();
    _updatePreview();
    notifyListeners();
  }
}

// 快捷操作数据类
class QuickActionItem {
  final String id;
  final IconData icon;
  final String label;
  final String cmd;
  final String? longCmd;

  QuickActionItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.cmd,
    this.longCmd,
  });
}
