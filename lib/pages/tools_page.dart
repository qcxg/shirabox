import 'package:flutter/material.dart';
import 'tools_shell_view.dart';
import 'tools_process_view.dart';
import 'tools_prop_view.dart';
import 'tools_inspector_view.dart';
// 引入 i18n
import '../l10n/app_localizations.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  String? _selectedTool;

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;

    if (_selectedTool != null) {
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedTool = null),
                ),
                const SizedBox(width: 8),
                Text(
                  _getTitle(_selectedTool!, i18n),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Expanded(child: _getToolView(_selectedTool!)),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(i18n.navTools,
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 32),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _ToolCard(
                title: i18n.toolsShell,
                icon: Icons.terminal,
                onTap: () => setState(() => _selectedTool = 'shell'),
              ),
              _ToolCard(
                title: i18n.toolsProcess,
                icon: Icons.memory,
                onTap: () => setState(() => _selectedTool = 'process'),
              ),
              _ToolCard(
                title: i18n.toolsProp,
                icon: Icons.settings_suggest,
                onTap: () => setState(() => _selectedTool = 'prop'),
              ),
              _ToolCard(
                title: i18n.toolsInspector,
                icon: Icons.search_off, // 或者用 Icons.biotech
                onTap: () => setState(() => _selectedTool = 'insp'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getTitle(String key, AppLocalizations i18n) {
    switch (key) {
      case 'shell':
        return i18n.toolsShell;
      case 'process':
        return i18n.toolsProcess;
      case 'prop':
        return i18n.toolsProp;
      case 'insp':
        return i18n.toolsInspector;
      default:
        return "";
    }
  }

  Widget _getToolView(String key) {
    switch (key) {
      case 'shell':
        return const ToolsShellView();
      case 'process':
        return const ToolsProcessView();
      case 'prop':
        return const ToolsPropView();
      case 'insp':
        return const ToolsInspectorView();
      default:
        return const SizedBox.shrink();
    }
  }
}

class _ToolCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _ToolCard({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    return SizedBox(
      width: 160,
      height: 120,
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: color.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withValues(alpha: 0.15)),
        ),
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 32, color: color),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
