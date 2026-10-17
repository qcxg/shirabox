import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/scrcpy_provider.dart';
import '../providers/app_state.dart';
import '../l10n/app_localizations.dart';

class ScrcpyView extends StatelessWidget {
  const ScrcpyView({super.key});

  // ... _showReorderDialog 保持不变 ...
  void _showReorderDialog(BuildContext context, ScrcpyProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Adjust Order (Drag)"),
        content: SizedBox(
          width: 300,
          height: 400,
          child: StatefulBuilder(
            builder: (context, setState) {
              return ReorderableListView(
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    provider.reorderActions(oldIndex, newIndex);
                  });
                },
                children: provider.quickActions.map((item) {
                  return ListTile(
                    key: ValueKey(item.id),
                    leading: Icon(item.icon),
                    title: Text(item.label),
                    trailing: const Icon(Icons.drag_handle),
                  );
                }).toList(),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Done")),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ScrcpyProvider>();
    context.read<AppState>();
    final i18n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // 1. Header (保持不变)
              Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.android,
                        size: 36, color: Colors.green),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(i18n.scrcpyTitle,
                            style: theme.textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(i18n.scrcpyIntro,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: Colors.grey)),
                      ],
                    ),
                  ),
                  if (provider.isRunning)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: IconButton.filled(
                        onPressed: () => provider.stopScrcpy(),
                        style: IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.errorContainer,
                          padding: const EdgeInsets.all(12),
                        ),
                        icon: Icon(Icons.stop, color: theme.colorScheme.error),
                      ),
                    ),
                  SizedBox(
                    height: 50,
                    width: 120,
                    child: FilledButton.icon(
                      onPressed: () => provider.startScrcpy(),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(i18n.scrcpyBtnStart,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // 2. 预览框 (保持不变)
              Text(i18n.scrcpyParamPreview, style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              TextField(
                controller: provider.cmdPreviewCtrl,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.3),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),

              const SizedBox(height: 24),

              // 3. Codec (保持不变)
              Row(
                children: [
                  const Icon(Icons.video_settings,
                      size: 20, color: Colors.grey),
                  const SizedBox(width: 12),
                  const Text("Codec:",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'h264', label: Text('H.264')),
                      ButtonSegment(value: 'h265', label: Text('H.265')),
                      ButtonSegment(value: 'av1', label: Text('AV1')),
                    ],
                    selected: {provider.videoCodec},
                    onSelectionChanged: (Set<String> newSelection) {
                      provider.updateParam(newCodec: newSelection.first);
                    },
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // 4. 双栏布局 (保持不变)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Column(
                      children: [
                        _buildSectionHeader(context, i18n.scrcpyGroupVideo),
                        Card(
                          elevation: 0,
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.3),
                          child: Column(
                            children: [
                              _buildSlider(context, i18n.scrcpyMaxSize,
                                  provider.maxSize.toDouble(), 0, 2560,
                                  label: provider.maxSize == 0
                                      ? "Original"
                                      : "${provider.maxSize}",
                                  onChanged: (v) => provider.updateParam(
                                      newMaxSize: v.toInt()),
                                  divisions: 2560 ~/ 64),
                              _buildSlider(
                                context,
                                i18n.scrcpyBitrate,
                                provider.bitRate.toDouble(),
                                1,
                                32,
                                label: "${provider.bitRate} Mbps",
                                onChanged: (v) =>
                                    provider.updateParam(newBitRate: v.toInt()),
                              ),
                              _buildSlider(
                                context,
                                i18n.scrcpyFps,
                                provider.maxFps.toDouble(),
                                0,
                                120,
                                label: provider.maxFps == 0
                                    ? "Unlimited"
                                    : "${provider.maxFps} FPS",
                                onChanged: (v) =>
                                    provider.updateParam(newFps: v.toInt()),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 6,
                    child: Column(
                      children: [
                        _buildSectionHeader(context, i18n.scrcpyGroupControl),
                        Card(
                          elevation: 0,
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.3),
                          child: Column(
                            children: [
                              SwitchListTile(
                                title: Text(i18n.scrcpyStayAwake),
                                value: provider.stayAwake,
                                onChanged: (v) =>
                                    provider.updateParam(newStayAwake: v),
                              ),
                              SwitchListTile(
                                title: Text(i18n.scrcpyTurnOffScreen),
                                value: provider.turnScreenOff,
                                onChanged: (v) =>
                                    provider.updateParam(newTurnScreenOff: v),
                              ),
                              SwitchListTile(
                                title: Text(i18n.scrcpyShowTouches),
                                value: provider.showTouches,
                                onChanged: (v) =>
                                    provider.updateParam(newShowTouches: v),
                              ),
                              SwitchListTile(
                                title: Text(i18n.scrcpyAlwaysOnTop),
                                value: provider.alwaysOnTop,
                                onChanged: (v) =>
                                    provider.updateParam(newAlwaysOnTop: v),
                              ),
                              SwitchListTile(
                                title: Text(i18n.scrcpyNoAudio),
                                value: provider.noAudio,
                                onChanged: (v) =>
                                    provider.updateParam(newNoAudio: v),
                              ),
                              SwitchListTile(
                                title: Text(i18n.scrcpyKeyNav),
                                subtitle: const Text(
                                    "Simulate physical keyboard (HID)"),
                                value: provider.keyboardNav,
                                onChanged: (v) =>
                                    provider.updateParam(newKeyboardNav: v),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // --- 2. 底部悬浮快捷操作栏 ---
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Material(
            elevation: 3,
            shadowColor: Colors.black.withValues(alpha: 0.1),
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 72,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  // ... 闪电图标和分割线保持不变 ...
                  Tooltip(
                    message: "Long press to reorder",
                    child: InkWell(
                      onLongPress: () => _showReorderDialog(context, provider),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child:
                            Icon(Icons.bolt, color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                  Container(
                      width: 1,
                      height: 30,
                      color: theme.colorScheme.outlineVariant,
                      margin: const EdgeInsets.symmetric(horizontal: 4)),

                  // 【核心修改】动态平分宽度
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: provider.quickActions.map((item) {
                        return Expanded(
                          // 每个按钮平分空间
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 2), // 间距调小
                            child: _SmallQuickBtn(
                              icon: item.icon,
                              label: item.label,
                              onTap: () {
                                final appState = Provider.of<AppState>(context,
                                    listen: false);
                                appState.adb.execShell(item.cmd);
                              },
                              onLongPress: item.longCmd != null
                                  ? () {
                                      final appState = Provider.of<AppState>(
                                          context,
                                          listen: false);
                                      appState.adb.execShell(item.longCmd!);
                                    }
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(title,
          style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildSlider(
      BuildContext context, String title, double value, double min, double max,
      {required String label,
      required Function(double) onChanged,
      int? divisions}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title),
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.blue)),
            ],
          ),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SmallQuickBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _SmallQuickBtn(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 【核心修改】去掉了 Tooltip 包裹
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 18, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSecondaryContainer),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
