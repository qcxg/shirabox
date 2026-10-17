import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../pages/home_page.dart';
import '../pages/apps/apps_page.dart';
import '../pages/files_page.dart';
import '../pages/tools_page.dart';
import '../pages/settings_page.dart';
import '../pages/logcat_page.dart';
import '../pages/scrcpy_view.dart'; // 引入投屏页面
import 'dart:io';
import '../l10n/app_localizations.dart';

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _selectedIndex = 0;

  // 显示设备切换小菜单
  void _showDeviceMenu(BuildContext context, AppState appState) {
    final theme = Theme.of(context);
    showMenu(
      context: context,
      // 定位到侧边栏图标右侧附近
      position: const RelativeRect.fromLTRB(80, 50, 100, 0),
      items: appState.devices.map((serial) {
        bool isCurrent = serial == appState.currentDevice;
        return PopupMenuItem(
          value: serial,
          child: Row(
            children: [
              Icon(
                isCurrent ? Icons.check_circle : Icons.phone_android,
                color: isCurrent ? theme.colorScheme.primary : Colors.grey,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                appState.getDeviceName(serial),
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent ? theme.colorScheme.primary : null,
                ),
              ),
            ],
          ),
          onTap: () => appState.switchDevice(serial),
        );
      }).toList(),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  // 無線連結對話框
  void _showWirelessDialog(BuildContext context, AppState appState) {
    final theme = Theme.of(context);
    final i18n = AppLocalizations.of(context)!;
    final ipCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: "5555"); // 預設 5555

    bool isCurrentlyConnected(String addr) {
      return appState.devices.contains(addr);
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.wifi, color: Colors.blue),
              const SizedBox(width: 8),
              Text(i18n.navWireless),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: ipCtrl,
                        decoration: InputDecoration(
                          labelText: i18n.wirelessIp,
                          hintText: "192.168.1.100",
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: portCtrl,
                        decoration: InputDecoration(
                          labelText: i18n.wirelessPort,
                          hintText: "5555",
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () {
                        final addr =
                            "${ipCtrl.text.trim()}:${portCtrl.text.trim()}";
                        if (ipCtrl.text.isNotEmpty &&
                            portCtrl.text.isNotEmpty) {
                          if (isCurrentlyConnected(addr)) {
                            appState.wirelessDisconnect(addr);
                          } else {
                            appState.wirelessConnect(addr);
                          }
                          Navigator.pop(context);
                        }
                      },
                      icon: Icon(isCurrentlyConnected(
                              "${ipCtrl.text.trim()}:${portCtrl.text.trim()}")
                          ? Icons.link_off
                          : Icons.send),
                    ),
                  ],
                ),
                if (appState.connectHistory.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(i18n.wirelessHistory,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: appState.connectHistory.length,
                      itemBuilder: (context, index) {
                        final item = appState.connectHistory[index];
                        final model = appState.historyModels[item];
                        final connected = isCurrentlyConnected(item);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.history, size: 18),
                          title: Row(
                            children: [
                              Text(item),
                              if (model != null) ...[
                                const SizedBox(width: 8),
                                Text("($model)",
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 12)),
                              ],
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                    connected ? Icons.link_off : Icons.link,
                                    size: 18,
                                    color: connected ? Colors.orange : null),
                                tooltip: connected
                                    ? i18n.wirelessDisconnect
                                    : i18n.wirelessConnect,
                                onPressed: () {
                                  if (connected) {
                                    appState.wirelessDisconnect(item);
                                  } else {
                                    appState.wirelessConnect(item);
                                  }
                                  Navigator.pop(context);
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.red),
                                tooltip: i18n.wirelessRemoveHistory,
                                onPressed: () {
                                  appState.removeHistory(item);
                                  setDialogState(() {});
                                },
                              ),
                            ],
                          ),
                          onTap: () {
                            if (connected) {
                              appState.wirelessDisconnect(item);
                            } else {
                              appState.wirelessConnect(item);
                            }
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(i18n.btnCancel),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    final isConnected = context.select<AppState, bool>((s) => s.isConnected);
    final deviceCount = context.select<AppState, int>((s) => s.devices.length);
    final i18n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final mustReturnHome =
        !isConnected && _selectedIndex != 0 && _selectedIndex != 6;
    final visibleIndex = mustReturnHome ? 0 : _selectedIndex;
    if (mustReturnHome) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state = context.read<AppState>();
        if (!state.isConnected && _selectedIndex != 0 && _selectedIndex != 6) {
          setState(() => _selectedIndex = 0);
        }
      });
    }

    // 页面路由配置
    final pages = [
      const HomePage(), // 0: 连接/首页
      const AppsPage(), // 1: 应用
      const FilesPage(), // 2: 文件
      const LogcatPage(), // 3: 日志
      const ToolsPage(), // 4: 工具 (Shell/Process)
      const ScrcpyView(), // 5: 投屏
      const SettingsPage(), // 6: 设置 (不在Rail中，通过底部按钮进入)
    ];

    return Scaffold(
      // 背景色由 Main.dart 的 Theme 控制 (Win11透明, Win10默认)
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: Colors.transparent,
            // 核心修复: destinations 只有 0-5，如果 selectedIndex 是 6，必须传 null
            selectedIndex: visibleIndex > 5 ? null : visibleIndex,
            labelType: NavigationRailLabelType.all,
            destinations: [
              // 0. 连接页 (动态图标)
              NavigationRailDestination(
                icon: deviceCount > 0
                    ? Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: theme
                              .colorScheme.surfaceContainerHighest, // 灰色圆圈背景
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$deviceCount',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      )
                    : const Icon(Icons.phonelink),
                label: Text(i18n.navConnect),
              ),

              // 1. 应用
              NavigationRailDestination(
                icon: const Icon(Icons.apps),
                label: Text(i18n.navApps),
              ),

              // 2. 文件
              NavigationRailDestination(
                icon: const Icon(Icons.folder_outlined),
                label: Text(i18n.navFiles),
              ),

              // 3. 日志
              NavigationRailDestination(
                icon: const Icon(Icons.bug_report_outlined),
                label: Text(i18n.navLogs),
              ),

              // 4. 工具
              NavigationRailDestination(
                icon: const Icon(Icons.terminal),
                label: Text(i18n.navTools),
              ),

              // 5. 投屏
              NavigationRailDestination(
                icon: const Icon(Icons.cast_connected),
                label: Text(i18n.navMirror),
              ),
            ],
            onDestinationSelected: (index) {
              // 逻辑: 如果点击的是首页(0)且设备数>1
              if (index == 0 && deviceCount > 1) {
                // 如果当前已经在首页，则弹出切换菜单
                if (visibleIndex == 0) {
                  _showDeviceMenu(context, appState);
                  return;
                }
                // 如果不在首页，先跳转回首页，再次点击才会出菜单（符合 Material 规范直觉）
              }

              // 未连接保护
              if (!isConnected && index != 0 && index != 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(i18n.homeWaitDevice),
                    width: 300,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
                return;
              }
              setState(() => _selectedIndex = index);
            },

            // 底部功能区
            trailing: Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Wireless Connection
                  IconButton(
                    icon: const Icon(Icons.wifi, color: Colors.blue),
                    tooltip: i18n.navWireless,
                    onPressed: () => _showWirelessDialog(context, appState),
                  ),

                  const SizedBox(height: 8),

                  // Power Menu
                  if (isConnected)
                    MenuAnchor(
                      builder: (context, controller, child) {
                        return IconButton(
                          onPressed: () {
                            if (controller.isOpen) {
                              controller.close();
                            } else {
                              controller.open();
                            }
                          },
                          icon: const Icon(
                            Icons.power_settings_new,
                            color: Colors.red,
                          ),
                          tooltip: i18n.tipPowerMenu,
                        );
                      },
                      menuChildren: [
                        MenuItemButton(
                          leadingIcon: const Icon(Icons.restart_alt),
                          child: Text(i18n.tipRestartSystem),
                          onPressed: () => appState.adb.reboot(),
                        ),
                        MenuItemButton(
                          leadingIcon: const Icon(Icons.build),
                          child: Text(i18n.tipRestartRecovery),
                          onPressed: () => appState.adb.rebootRecovery(),
                        ),
                        MenuItemButton(
                          leadingIcon: const Icon(Icons.developer_board),
                          child: Text(i18n.tipRestartBootloader),
                          onPressed: () => appState.adb.rebootBootloader(),
                        ),
                        const Divider(),
                        MenuItemButton(
                          leadingIcon: const Icon(
                            Icons.power_off,
                            color: Colors.red,
                          ),
                          child: Text(
                            i18n.tipShutdown,
                            style: const TextStyle(color: Colors.red),
                          ),
                          onPressed: () => appState.adb.shutdown(),
                        ),
                      ],
                    ),

                  const SizedBox(height: 8),

                  // Kill Server
                  IconButton(
                    icon: const Icon(Icons.portable_wifi_off,
                        color: Colors.orange),
                    tooltip: i18n.tipKillServer,
                    onPressed: () async {
                      await appState.adb
                          .runSafe(['kill-server'], includeTarget: false);
                      exit(0);
                    },
                  ),

                  const SizedBox(height: 8),

                  // Settings (Index 6)
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: i18n.navSettings,
                    onPressed: () => setState(() => _selectedIndex = 6),
                    style: IconButton.styleFrom(
                      foregroundColor: visibleIndex == 6
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Refresh
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: i18n.tipRefresh,
                    onPressed: () => appState.checkDevices(),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: pages[visibleIndex],
            ),
          ),
        ],
      ),
    );
  }
}
