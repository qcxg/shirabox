import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../providers/scrcpy_provider.dart';
import '../../l10n/app_localizations.dart';

class AppListItem extends StatelessWidget {
  final AppData app;
  final bool isSelectionMode;
  final VoidCallback? onTap;
  final Function(String) onAction;

  const AppListItem({
    super.key,
    required this.app,
    required this.isSelectionMode,
    this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;

    return RepaintBoundary(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
        dense: true,
        leading: isSelectionMode
            ? Checkbox(value: app.isSelected, onChanged: (_) => onTap?.call())
            : _AppIcon(
                packageName: app.packageName, displayName: app.displayName),
        title: Text(
          app.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            decoration: app.isEnabled ? null : TextDecoration.lineThrough,
            color: app.isEnabled ? null : Colors.grey,
          ),
        ),
        subtitle: Row(
          children: [
            Expanded(
                child: Text(app.packageName,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (app.isSplit) const _Tag(text: "Split", color: Colors.blue),
            if (app.isSystem) const _Tag(text: "Sys", color: Colors.orange),
          ],
        ),
        onTap: isSelectionMode ? onTap : null,
        trailing: isSelectionMode
            ? null
            : _ActionMenu(app: app, onAction: onAction, i18n: i18n),
      ),
    );
  }
}

// ... _AppIcon 和 _Tag 保持不变 ...
class _AppIcon extends StatelessWidget {
  final String packageName;
  final String displayName;
  const _AppIcon({required this.packageName, required this.displayName});
  @override
  Widget build(BuildContext context) {
    final iconBytes = context
        .select<AppState, Uint8List?>((s) => s.getCachedIcon(packageName));
    if (iconBytes != null) {
      return CircleAvatar(backgroundImage: MemoryImage(iconBytes));
    }
    return CircleAvatar(
      backgroundColor: Colors
          .primaries[packageName.hashCode.abs() % Colors.primaries.length]
          .withValues(alpha: 0.2),
      child: Text(displayName.isEmpty ? "?" : displayName[0].toUpperCase(),
          style: const TextStyle(fontWeight: FontWeight.bold)),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final MaterialColor color;
  const _Tag({required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
          borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(fontSize: 9, color: color)),
    );
  }
}

class _ActionMenu extends StatelessWidget {
  final AppData app;
  final Function(String) onAction;
  final AppLocalizations i18n;

  const _ActionMenu(
      {required this.app, required this.onAction, required this.i18n});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      itemBuilder: (ctx) => [
        if (!app.isSplit)
          PopupMenuItem(value: 'extract', child: Text(i18n.actionExtractApk)),
        if (app.isSplit)
          PopupMenuItem(
              value: 'extract_all', child: Text(i18n.actionExtractAll)),
        PopupMenuItem(
            value: 'toggle',
            child: Text(app.isEnabled ? i18n.actionFreeze : i18n.actionUnfreeze,
                style: TextStyle(
                    color: app.isEnabled ? Colors.red : Colors.green))),
        PopupMenuItem(
            value: 'uninstall',
            child: Text(i18n.actionUninstall,
                style: const TextStyle(color: Colors.red))),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'open',
          child: Row(children: [
            const Icon(Icons.launch, size: 18),
            const SizedBox(width: 8),
            Text(i18n.actionOpen),
          ]),
        ),
        PopupMenuItem(
          enabled: false, // 禁用內部選中邏輯，改由自定義 Widget 處理
          child: StatefulBuilder(builder: (context, setPopupState) {
            return InkWell(
              onTap: () {
                appState.setLaunchWithMirror(!appState.launchWithMirror);
                setPopupState(() {}); // 刷新彈窗內部的複選框狀態
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: appState.launchWithMirror,
                        onChanged: (v) {
                          appState.setLaunchWithMirror(v ?? false);
                          setPopupState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      i18n.appsLaunchWithMirror,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ],
      onSelected: (value) async {
        if (value == 'open') {
          await appState.launchApp(app.packageName);
          if (appState.launchWithMirror && context.mounted) {
            context.read<ScrcpyProvider>().startScrcpy();
          }
        } else {
          onAction(value);
        }
      },
    );
  }
}
