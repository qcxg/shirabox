// ... 其他 import 保持不变
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../../providers/app_state.dart';
import 'app_list_item.dart';
import 'install_dialog.dart';
import '../../l10n/app_localizations.dart';

class AppsPage extends StatefulWidget {
  const AppsPage({super.key});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  // ... 变量保持不变 ...
  bool _showSystemApps = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.read<AppState>().appList.isEmpty) {
        _loadData();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    await context.read<AppState>().fetchApps();
  }

  // ... _extractApk, _batchExtract 保持不变 ...
  Future<void> _extractApk(AppData app) async {
    final appState = context.read<AppState>();
    final i18n = AppLocalizations.of(context)!;
    final serial = appState.currentDevice;
    if (serial == null) return;
    String? outputDir = await FilePicker.platform.getDirectoryPath();
    if (outputDir != null) {
      appState.addLog("Extracting ${app.packageName} ...");
      try {
        await appState.files.extractApp(
          app.packageName,
          outputDir,
          app.splitPaths,
          app.path,
          serial: serial,
        );
        appState.addLog("Extract Done");
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(i18n.appsExtractSuccess)));
        }
      } catch (e) {
        appState.addLog("Extract Failed: $e");
      }
    }
  }

  Future<void> _batchExtract() async {
    final appState = context.read<AppState>();
    final i18n = AppLocalizations.of(context)!;
    String? outputDir = await FilePicker.platform.getDirectoryPath();
    if (outputDir != null) {
      await appState.extractSelectedApps(outputDir);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(i18n.appsBatchExtractFinish)));
      }
    }
  }

  // 【核心修复】拖拽安装后的处理
  Future<void> _handleDrop(List<dynamic> files) async {
    final paths = files.map((f) => f.path.toString()).toList(growable: false);
    await _handleInstallPaths(paths);
  }

  Future<void> _pickInstallFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['apk', 'xapk', 'apks'],
    );
    if (!mounted || result == null) return;
    await _handleInstallPaths(result.paths.whereType<String>().toList());
  }

  Future<void> _handleInstallPaths(List<String> paths) async {
    final validFiles = paths.where((path) {
      final lower = path.toLowerCase();
      return lower.endsWith('.apk') ||
          lower.endsWith('.xapk') ||
          lower.endsWith('.apks');
    }).toList();

    if (validFiles.isNotEmpty) {
      context
          .read<AppState>()
          .addLog('Install batch received: ${validFiles.length} item(s)');
      // 等待弹窗关闭，并获取返回值 (是否有成功安装)
      final bool? hasSuccess = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => InstallDialog(filePaths: validFiles));

      // 如果有安装成功，延迟刷新
      if (hasSuccess == true && mounted) {
        final i18n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(i18n.installSuccessToast), // "安装完成，正在刷新..."
            duration: const Duration(seconds: 1)));

        // 【关键】延迟 1.5 秒，等待系统缓存更新
        await Future.delayed(const Duration(milliseconds: 1500));

        if (mounted) _loadData(); // 刷新列表
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final i18n = AppLocalizations.of(context)!;

    final filteredApps = appState.appList.where((app) {
      if (!_showSystemApps && app.isSystem) return false;
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        return app.packageName.toLowerCase().contains(q) ||
            app.displayName.toLowerCase().contains(q);
      }
      return true;
    }).toList();

    return Column(
      children: [
        _AppsHeader(
          showSystemApps: _showSystemApps,
          onShowSystemChanged: (v) => setState(() => _showSystemApps = v),
          searchController: _searchController,
          onSearchChanged: (v) => setState(() => _searchQuery = v),
          isSelectionMode: appState.isSelectionMode,
          onSelectionModeChanged: (v) => appState.toggleSelectionMode(v),
          onRefresh: _loadData,
          i18n: i18n,
        ),
        if (appState.isLoadingApps) const LinearProgressIndicator(minHeight: 2),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: _AppsList(
                  apps: filteredApps,
                  isSelectionMode: appState.isSelectionMode,
                  onAppTap: (app) => appState.toggleAppSelection(app),
                  onAction: (app, action) {
                    if (action == 'toggle') appState.toggleAppEnable(app);
                    if (action == 'extract' || action == 'extract_all') {
                      _extractApk(app);
                    }
                    if (action == 'uninstall') {
                      appState.adb
                          .runSafe(['uninstall', app.packageName])
                          .then((_) => _loadData())
                          .catchError((Object error) {
                            appState.addLog(
                                'Uninstall failed (${app.packageName}): $error');
                          });
                    }
                  },
                  emptyText: i18n.appsEmpty,
                ),
              ),
              const VerticalDivider(width: 1),
              _DropZone(
                onDrop: _handleDrop,
                onPick: _pickInstallFiles,
                hint: i18n.appsDropHint,
                chooseLabel: i18n.appsChoosePackages,
              ),
            ],
          ),
        ),
        if (appState.isSelectionMode)
          _AppsSelectionBar(
            selectedCount: appState.appList.where((e) => e.isSelected).length,
            onSelectAll: () => appState.selectAll(true),
            onDeselectAll: () => appState.selectAll(false),
            onBatchExtract: _batchExtract,
            i18n: i18n,
          ),
      ],
    );
  }
}

class _AppsHeader extends StatelessWidget {
  final bool showSystemApps;
  final ValueChanged<bool> onShowSystemChanged;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final bool isSelectionMode;
  final ValueChanged<bool> onSelectionModeChanged;
  final VoidCallback onRefresh;
  final AppLocalizations i18n;

  const _AppsHeader({
    required this.showSystemApps,
    required this.onShowSystemChanged,
    required this.searchController,
    required this.onSearchChanged,
    required this.isSelectionMode,
    required this.onSelectionModeChanged,
    required this.onRefresh,
    required this.i18n,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          Text(i18n.appsSystemApps),
          Switch(value: showSystemApps, onChanged: onShowSystemChanged),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                  hintText: i18n.appsSearchHint,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: const OutlineInputBorder()),
              onChanged: onSearchChanged,
            ),
          ),
          const SizedBox(width: 16),
          FilterChip(
              label: Text(i18n.appsMultiSelect),
              selected: isSelectionMode,
              onSelected: onSelectionModeChanged),
          const SizedBox(width: 8),
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: onRefresh,
              tooltip: i18n.appsRefresh),
        ],
      ),
    );
  }
}

class _AppsList extends StatelessWidget {
  final List<AppData> apps;
  final bool isSelectionMode;
  final Function(AppData) onAppTap;
  final Function(AppData, String) onAction;
  final String emptyText;

  const _AppsList({
    required this.apps,
    required this.isSelectionMode,
    required this.onAppTap,
    required this.onAction,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    if (apps.isEmpty) return Center(child: Text(emptyText));
    return ListView.builder(
      itemCount: apps.length,
      itemExtent: 64,
      itemBuilder: (ctx, index) {
        final app = apps[index];
        return AppListItem(
          app: app,
          isSelectionMode: isSelectionMode,
          onTap: () => onAppTap(app),
          onAction: (action) => onAction(app, action),
        );
      },
    );
  }
}

class _DropZone extends StatelessWidget {
  final Function(List<dynamic>) onDrop;
  final VoidCallback onPick;
  final String hint;
  final String chooseLabel;

  const _DropZone({
    required this.onDrop,
    required this.onPick,
    required this.hint,
    required this.chooseLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: 1,
      child: DropTarget(
        onDragDone: (detail) => onDrop(detail.files),
        child: Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.5),
                  width: 2),
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).primaryColor.withValues(alpha: 0.05)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.install_mobile,
                size: 48, color: Theme.of(context).primaryColor),
            const SizedBox(height: 16),
            Text(hint, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.file_open),
              label: Text(chooseLabel),
            ),
          ]),
        ),
      ),
    );
  }
}

class _AppsSelectionBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback onSelectAll;
  final VoidCallback onDeselectAll;
  final VoidCallback onBatchExtract;
  final AppLocalizations i18n;

  const _AppsSelectionBar({
    required this.selectedCount,
    required this.onSelectAll,
    required this.onDeselectAll,
    required this.onBatchExtract,
    required this.i18n,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Text(i18n.appsSelected(selectedCount)),
          const SizedBox(width: 16),
          TextButton(onPressed: onSelectAll, child: Text(i18n.appsSelectAll)),
          TextButton(onPressed: onDeselectAll, child: Text(i18n.appsDeselect)),
          const Spacer(),
          FilledButton.icon(
              onPressed: onBatchExtract,
              icon: const Icon(Icons.save_alt),
              label: Text(i18n.appsBatchExtract)),
        ],
      ),
    );
  }
}
