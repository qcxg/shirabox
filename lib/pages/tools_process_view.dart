import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../services/adb_process.dart';
// 引入 i18n
import '../../l10n/app_localizations.dart';

class ToolsProcessView extends StatefulWidget {
  const ToolsProcessView({super.key});

  @override
  State<ToolsProcessView> createState() => _ToolsProcessViewState();
}

class _ToolsProcessViewState extends State<ToolsProcessView> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<ProcessInfo> _allProcesses = [];
  List<ProcessInfo> _displayProcesses = [];

  bool _loading = false;
  bool _showLinux = false;

  bool _autoRefresh = false;
  Timer? _timer;
  Future<void>? _refreshInFlight;
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refreshProcess();
  }

  @override
  void dispose() {
    _refreshGeneration++;
    _timer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleAutoRefresh(bool enable) {
    setState(() => _autoRefresh = enable);
    _timer?.cancel();
    if (enable) {
      _timer = Timer.periodic(
          const Duration(seconds: 2), (_) => _refreshProcess(silent: true));
      _refreshProcess(silent: true);
    }
  }

  void _applyFilter() {
    if (!mounted) return;
    setState(() => _displayProcesses = _filterProcesses(_allProcesses));
  }

  List<ProcessInfo> _filterProcesses(List<ProcessInfo> processes) {
    final query = _searchCtrl.text.toLowerCase();
    return processes.where((p) {
      if (p.name.isEmpty) return false;
      if (!_showLinux && !p.isAndroid) return false;
      if (query.isNotEmpty) {
        return p.name.toLowerCase().contains(query) || p.pid.contains(query);
      }
      return true;
    }).toList();
  }

  Future<void> _refreshProcess({bool silent = false}) async {
    if (!mounted) return;

    final existing = _refreshInFlight;
    if (existing != null) {
      return;
    }

    final appState = context.read<AppState>();
    final serial = appState.currentDevice;
    if (!appState.isConnected || serial == null) return;

    final generation = ++_refreshGeneration;
    if (!silent) setState(() => _loading = true);

    final operation = _performRefresh(appState, serial, generation);
    _refreshInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
      }
    }
  }

  Future<void> _performRefresh(
      AppState appState, String serial, int generation) async {
    try {
      final list = await appState.processes.getProcessList();
      if (!mounted ||
          generation != _refreshGeneration ||
          !appState.isConnected ||
          appState.currentDevice != serial) {
        return;
      }

      setState(() {
        _allProcesses = list;
        _displayProcesses = _filterProcesses(list);
        _loading = false;
      });
    } catch (_) {
      // The service normally converts command failures to an empty list. Keep
      // the poll loop alive if an unexpected process error still escapes.
    } finally {
      if (mounted && generation == _refreshGeneration && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _killProcess(ProcessInfo p) async {
    final i18n = AppLocalizations.of(context)!;
    if (!mounted) return;
    bool wasAuto = _autoRefresh;
    if (wasAuto) _toggleAutoRefresh(false);

    final appState = context.read<AppState>();
    String? error;

    if (p.name.contains('.') && p.name.length > 5) {
      try {
        await appState.adb.runSafe(['shell', 'am', 'force-stop', p.name]);
        error = null;
      } catch (e) {
        error = e.toString();
      }
    }

    if (error != null || !p.name.contains('.')) {
      error = await appState.processes.killProcess(p.pid);
    }

    if (mounted) {
      if (error == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(i18n.processKillSuccess(p.name)), // "已结束: xxx"
            duration: const Duration(milliseconds: 800)));
        _refreshProcess();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(i18n.processKillFail(error)), // "结束失败: xxx"
          backgroundColor: Colors.red,
        ));
      }
      if (wasAuto) _toggleAutoRefresh(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Text(i18n.processShowSystem), // "显示系统进程"
              Switch(
                  value: _showLinux,
                  onChanged: (v) {
                    setState(() {
                      _showLinux = v;
                      _displayProcesses = _filterProcesses(_allProcesses);
                    });
                  }),
              const SizedBox(width: 16),
              Text(i18n.processAutoRefresh), // "自动刷新"
              Switch(value: _autoRefresh, onChanged: _toggleAutoRefresh),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: i18n.processSearchHint, // "搜索进程名..."
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => _applyFilter(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _refreshProcess(),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(i18n.processBtnRefresh), // "刷新"
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.builder(
            itemCount: _displayProcesses.length,
            itemExtent: 50,
            itemBuilder: (context, index) {
              final p = _displayProcesses[index];

              bool canKill = p.user.startsWith('u0_') || p.name.contains('.');
              bool isActive = p.cpu != "0%" && p.cpu != "0.0%";

              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(Icons.circle,
                    size: 8, color: isActive ? Colors.green : Colors.grey),
                minLeadingWidth: 10,
                title: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight:
                            isActive ? FontWeight.w900 : FontWeight.bold)),
                subtitle: Row(
                  children: [
                    Text("PID:${p.pid}",
                        style: const TextStyle(
                            fontFamily: 'Consolas', fontSize: 12)),
                    const SizedBox(width: 8),
                    Text(p.user,
                        style:
                            const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(p.cpu,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isActive ? Colors.red : null)),
                        Text(p.res,
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(width: 8),
                    if (canKill)
                      IconButton(
                        icon: const Icon(Icons.close,
                            size: 18, color: Colors.red),
                        tooltip: i18n.processBtnKill, // "结束进程"
                        onPressed: () => _killProcess(p),
                      )
                    else
                      const SizedBox(width: 40),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
