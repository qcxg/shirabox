import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
// 引入 i18n
import '../l10n/app_localizations.dart';

class ToolsShellView extends StatefulWidget {
  const ToolsShellView({super.key});

  @override
  State<ToolsShellView> createState() => _ToolsShellViewState();
}

class _ToolsShellViewState extends State<ToolsShellView> {
  final TextEditingController _cmdController = TextEditingController();
  String _shellOutput = "";
  bool _loading = false;

  @override
  void dispose() {
    _cmdController.dispose();
    super.dispose();
  }

  Future<void> _runShell() async {
    final cmd = _cmdController.text.trim();
    if (cmd.isEmpty) return;

    final appState = context.read<AppState>();
    setState(() => _loading = true);

    try {
      final result = await appState.adb.runScript(cmd);
      if (mounted) {
        setState(() => _shellOutput = result.isEmpty ? "[No Output]" : result);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _shellOutput = "Error: $e");
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;
    // 修复 deprecated withOpacity -> withValues
    final bgColor = const Color(0xFF252525).withValues(alpha: 0.8);
    final borderColor = Colors.white.withValues(alpha: 0.1);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                "adb shell ",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Consolas',
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  style: const TextStyle(fontFamily: 'Consolas'),
                  decoration: const InputDecoration(
                    hintText: "ls -l",
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runShell(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: _runShell, child: Text(i18n.shellBtnRun)), // "执行"
            ],
          ),
          SizedBox(
            height: 4,
            child: _loading ? const LinearProgressIndicator() : null,
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _shellOutput,
                  style: const TextStyle(
                    color: Color(0xFF4CAF50),
                    fontFamily: 'Consolas',
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
