import 'dart:async';
import 'dart:io';
import 'dart:ui'; // PlatformDispatcher 需要这个引用
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:window_manager/window_manager.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';

import 'services/adb_core.dart';
import 'widgets/main_layout.dart';
import 'providers/app_state.dart';
import 'providers/scrcpy_provider.dart';
import 'providers/logcat_provider.dart';
import 'providers/file_transfer_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  await Window.initialize();

  final prefs = await SharedPreferences.getInstance();
  final double? savedW = prefs.getDouble('win_w');
  final double? savedH = prefs.getDouble('win_h');
  final double? savedX = prefs.getDouble('win_x');
  final double? savedY = prefs.getDouble('win_y');
  final bool isMaximized = prefs.getBool('win_max') ?? false;

  Size initialSize = const Size(1000, 700);
  if (savedW != null && savedH != null) {
    initialSize = Size(savedW, savedH);
  }

  bool isWin11 = false;
  if (Platform.isWindows) {
    final deviceInfo = DeviceInfoPlugin();
    final windowsInfo = await deviceInfo.windowsInfo;
    if (windowsInfo.buildNumber >= 22000) {
      isWin11 = true;
    }

    WindowOptions windowOptions = WindowOptions(
      size: initialSize,
      minimumSize: const Size(800, 600),
      center: false,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      title: "Shirabox",
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (isWin11) {
        await Window.setEffect(effect: WindowEffect.mica, dark: false);
      } else {
        await windowManager.setBackgroundColor(const Color(0xFFF3F3F3));
      }

      if (isMaximized) {
        await windowManager.maximize();
      } else if (savedW != null &&
          savedH != null &&
          savedX != null &&
          savedY != null) {
        await windowManager
            .setBounds(Rect.fromLTWH(savedX, savedY, savedW, savedH));
      } else {
        await windowManager.center();
      }

      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    MultiProvider(
      providers: [
        Provider(
          create: (_) => AdbCore(
            adbPath: prefs.getString('adb_path') ?? 'adb',
            checkOnCreate: false,
          ),
        ),
        ChangeNotifierProvider(create: (_) => FileTransferProvider()),
        ChangeNotifierProvider(
          create: (context) => AppState(context.read<AdbCore>()),
        ),

        ChangeNotifierProxyProvider<AppState, LogcatProvider>(
          create: (context) =>
              LogcatProvider(context.read<AppState>().processes),
          update: (context, appState, previous) {
            // 如果 previous 为空，说明是第一次创建
            final provider = previous ?? LogcatProvider(appState.processes);
            // 【关键】通知 LogcatProvider 设备变了
            provider.handleDeviceChange(appState.currentDevice);
            return provider;
          },
        ),

        // 【核心修改】ScrcpyProvider 联动
        ChangeNotifierProxyProvider<AppState, ScrcpyProvider>(
          create: (context) => ScrcpyProvider(context.read<AppState>()),
          update: (context, appState, previous) {
            final provider = previous ?? ScrcpyProvider(appState);
            // 【关键】通知 ScrcpyProvider 设备变了
            provider.handleDeviceChange();
            return provider;
          },
        ),
      ],
      child: AdbToolboxApp(isWin11: isWin11),
    ),
  );
}

class DesktopScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
      };
}

// 【修复】使用 PlatformDispatcher.instance 替代 window
List<String> _getFontFamilyFallback(Locale? appLocale) {
  // PlatformDispatcher.instance.locale 在新版 Flutter 中不为空，所以不需要 ?? 处理
  final Locale effectiveLocale =
      appLocale ?? PlatformDispatcher.instance.locale;

  switch (effectiveLocale.languageCode) {
    case 'zh':
      if (effectiveLocale.countryCode == 'TW' ||
          effectiveLocale.countryCode == 'HK') {
        return ['Microsoft JhengHei UI', 'Segoe UI'];
      }
      return ['Microsoft YaHei UI', 'Segoe UI'];
    case 'ja':
      return ['Yu Gothic UI', 'Meiryo UI', 'Segoe UI'];
    case 'en':
    default:
      return ['Segoe UI', 'Microsoft YaHei UI'];
  }
}

class AdbToolboxApp extends StatefulWidget {
  final bool isWin11;
  const AdbToolboxApp({super.key, required this.isWin11});

  @override
  State<AdbToolboxApp> createState() => _AdbToolboxAppState();
}

class _AdbToolboxAppState extends State<AdbToolboxApp> with WindowListener {
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _saveDebounce?.cancel();
    super.dispose();
  }

  void _saveWindowState() {
    if (_saveDebounce?.isActive ?? false) _saveDebounce!.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      bool isMaximized = await windowManager.isMaximized();
      await prefs.setBool('win_max', isMaximized);

      if (!isMaximized) {
        Rect bounds = await windowManager.getBounds();
        await prefs.setDouble('win_w', bounds.width);
        await prefs.setDouble('win_h', bounds.height);
        await prefs.setDouble('win_x', bounds.left);
        await prefs.setDouble('win_y', bounds.top);
      }
    });
  }

  @override
  void onWindowMoved() => _saveWindowState();
  @override
  void onWindowResized() => _saveWindowState();
  @override
  void onWindowMaximize() => _saveWindowState();
  @override
  void onWindowUnmaximize() => _saveWindowState();

  @override
  Widget build(BuildContext context) {
    final appLocale = context.select<AppState, Locale?>((s) => s.locale);
    final seedColor = context.select<AppState, Color>((s) => s.seedColor);

    // 动态字体
    final fontFallbacks = _getFontFamilyFallback(appLocale);
    final fontFamily = fontFallbacks.first;

    return MaterialApp(
      title: 'Shirabox',
      debugShowCheckedModeBanner: false,
      scrollBehavior: DesktopScrollBehavior(),
      locale: appLocale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', ''),
        Locale('zh', 'TW'),
        Locale('en', ''),
        Locale('ja', ''),
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seedColor,
        brightness: Brightness.light,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFallbacks,
        scaffoldBackgroundColor: widget.isWin11 ? Colors.transparent : null,
        cardTheme: const CardThemeData(elevation: 0, color: Colors.transparent),
      ),
      home: const MainLayout(),
    );
  }
}
