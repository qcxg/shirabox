import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../l10n/app_localizations.dart';

class ToolsPropView extends StatefulWidget {
  const ToolsPropView({super.key});

  @override
  State<ToolsPropView> createState() => _ToolsPropViewState();
}

class _ToolsPropViewState extends State<ToolsPropView> {
  Map<String, String> _allProps = {};
  Map<String, String> _filteredProps = {};
  bool _isLoading = false;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProps();
  }

  Future<void> _loadProps() async {
    setState(() => _isLoading = true);
    final props = await context.read<AppState>().adb.getAllProps();
    setState(() {
      _allProps = props;
      _filteredProps = Map.from(props);
      _isLoading = false;
      _applyFilter(_searchCtrl.text);
    });
  }

  void _applyFilter(String query) {
    if (query.isEmpty) {
      setState(() => _filteredProps = Map.from(_allProps));
      return;
    }
    final lowerQuery = query.toLowerCase();
    setState(() {
      _filteredProps = Map.fromEntries(_allProps.entries.where((e) =>
          e.key.toLowerCase().contains(lowerQuery) ||
          e.value.toLowerCase().contains(lowerQuery)));
    });
  }

  Future<void> _editProp(String key, String currentValue) async {
    final i18n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: currentValue);
    final newValue = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n.toolsPropEditTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(key,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(i18n.btnCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text("OK")),
        ],
      ),
    );

    if (newValue != null && newValue != currentValue && mounted) {
      try {
        await context.read<AppState>().adb.setProp(key, newValue);
        _loadProps();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("Error: $e")));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: i18n.toolsPropSearch,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onChanged: _applyFilter,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        i18n.toolsPropWarning,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.orangeAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: _filteredProps.length,
                  itemBuilder: (ctx, index) {
                    final key = _filteredProps.keys.elementAt(index);
                    final val = _filteredProps[key]!;
                    return ListTile(
                      dense: true,
                      title: Text(key,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(val,
                          style: TextStyle(color: theme.colorScheme.primary)),
                      trailing: const Icon(Icons.edit, size: 16),
                      onTap: () => _editProp(key, val),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
