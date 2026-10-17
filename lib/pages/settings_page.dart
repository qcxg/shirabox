// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/app_state.dart';
// 引入本地生成的 l10n
import '../l10n/app_localizations.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final i18n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final List<Map<String, dynamic>> themeOptions = [
      {'color': Colors.deepPurple, 'name': i18n.colorPurple},
      {'color': Colors.blue, 'name': i18n.colorBlue},
      {'color': Colors.green, 'name': i18n.colorGreen},
      {'color': Colors.redAccent, 'name': i18n.colorRed},
      {'color': Colors.orange, 'name': i18n.colorOrange},
      {'color': Colors.pinkAccent, 'name': i18n.colorPink},
      {'color': const Color(0xFF424242), 'name': i18n.colorGrey},
      {'color': Colors.teal, 'name': i18n.colorTeal},
      {'color': Colors.indigo, 'name': i18n.colorIndigo},
      {'color': Colors.brown, 'name': i18n.colorBrown},
    ];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(i18n.settingsTitle, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 24),
        _buildSectionTitle(context, i18n.settingsTheme),
        Card(
          elevation: 0,
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ExpansionTile(
                leading: const Icon(Icons.language),
                title: Text(i18n.settingsLanguage),
                subtitle: Text(_getCurrentLanguageName(appState.locale)),
                shape: const Border(),
                children: [
                  _buildLanguageItem(appState, null, "跟随系统 (System Default)"),
                  _buildLanguageItem(appState, const Locale('zh'), "简体中文"),
                  _buildLanguageItem(
                      appState, const Locale('zh', 'TW'), "繁體中文"),
                  _buildLanguageItem(appState, const Locale('en'), "English"),
                  _buildLanguageItem(appState, const Locale('ja'), "日本語"),
                ],
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ExpansionTile(
                leading: const Icon(Icons.color_lens_outlined),
                title: Text(i18n.settingsTheme),
                subtitle: Text(
                    _getCurrentThemeName(appState.seedColor, themeOptions)),
                shape: const Border(),
                children: themeOptions.map((option) {
                  final Color color = option['color'];
                  final String name = option['name'];
                  final bool isSelected =
                      appState.seedColor.value == color.value;
                  return ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                    leading: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                    ),
                    title: Text(name),
                    trailing: isSelected
                        ? Icon(Icons.check, color: theme.colorScheme.primary)
                        : null,
                    onTap: () {
                      appState.updateThemeColor(color);
                    },
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _buildSectionTitle(context, i18n.settingsAdbPath),
        Card(
          elevation: 0,
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.code),
                title: Text(i18n.settingsAdbManual),
                subtitle: Text(appState.customAdbPath.isEmpty
                    ? (appState.isAdbFallback
                        ? i18n.settingsAdbFallback
                        : "System Default")
                    : appState.customAdbPath),
                trailing: const Icon(Icons.folder_open),
                onTap: () async {
                  FilePickerResult? result =
                      await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['exe'],
                  );
                  if (result != null && context.mounted) {
                    context
                        .read<AppState>()
                        .updateSettings(adbPath: result.files.single.path!);
                  }
                },
              ),
              if (appState.customAdbPath.isNotEmpty) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: Text(i18n.settingsAdbReset),
                  onTap: () =>
                      context.read<AppState>().updateSettings(adbPath: ""),
                ),
              ]
            ],
          ),
        ),
        const SizedBox(height: 24),
        _buildSectionTitle(context, i18n.settingsQuickBoot),
        Card(
          elevation: 0,
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.rocket_launch_outlined),
                title: Text(i18n.settingsShowQuick),
                value: appState.showQuickBoot,
                onChanged: (v) =>
                    context.read<AppState>().updateSettings(showQuick: v),
              ),
              if (appState.showQuickBoot) ...[
                const Divider(height: 1),
                ...appState.quickCommands.map((cmd) {
                  return ListTile(
                    leading: const Icon(Icons.terminal, size: 20),
                    title: Text(cmd.name),
                    subtitle: Text(cmd.command,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        final newList =
                            List<QuickCommand>.from(appState.quickCommands)
                              ..remove(cmd);
                        context.read<AppState>().updateQuickCommands(newList);
                      },
                    ),
                  );
                }),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(i18n.btnAddCustom),
                  onTap: () => _showAddCommandDialog(context, i18n),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 40),
        Center(
          child: Column(
            children: [
              Text("Shirabox v${appState.appVersion}",
                  style: const TextStyle(color: Colors.grey, fontSize: 14)),
              const SizedBox(height: 4),
              Text("Designed by Shirakara",
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.5),
                      fontSize: 12,
                      fontStyle: FontStyle.italic)),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildLanguageItem(AppState appState, Locale? value, String text) {
    return RadioListTile<Locale?>(
      value: value,
      groupValue: appState.locale,
      onChanged: (val) => appState.changeLanguage(val),
      title: Text(text),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
    );
  }

  String _getCurrentLanguageName(Locale? locale) {
    if (locale == null) return "跟随系统 (System Default)";
    if (locale.languageCode == 'zh') {
      return locale.countryCode == 'TW' ? "繁體中文" : "简体中文";
    }
    if (locale.languageCode == 'en') return "English";
    if (locale.languageCode == 'ja') return "日本語";
    return locale.toString();
  }

  String _getCurrentThemeName(Color color, List<Map<String, dynamic>> options) {
    try {
      final option =
          options.firstWhere((opt) => opt['color'].value == color.value);
      return option['name'];
    } catch (_) {
      return "Custom";
    }
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 8),
      child: Text(title,
          style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: 14)),
    );
  }

  void _showAddCommandDialog(BuildContext context, AppLocalizations i18n) {
    final nameCtrl = TextEditingController();
    final cmdCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n.dialogAddTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtrl,
                decoration: InputDecoration(labelText: i18n.dialogName)),
            const SizedBox(height: 8),
            TextField(
                controller: cmdCtrl,
                decoration: InputDecoration(labelText: i18n.dialogCommand)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(i18n.btnCancel)),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty && cmdCtrl.text.isNotEmpty) {
                final newCmd =
                    QuickCommand(name: nameCtrl.text, command: cmdCtrl.text);
                if (context.mounted) {
                  final appState =
                      Provider.of<AppState>(context, listen: false);
                  final newList =
                      List<QuickCommand>.from(appState.quickCommands)
                        ..add(newCmd);
                  appState.updateQuickCommands(newList);
                }
                Navigator.pop(ctx);
              }
            },
            child: Text(i18n.btnAdd),
          ),
        ],
      ),
    );
  }
}
