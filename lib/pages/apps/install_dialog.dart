import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../services/operation_context.dart';

class InstallDialog extends StatefulWidget {
  final List<String> filePaths;
  const InstallDialog({super.key, required this.filePaths});
  @override
  State<InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<InstallDialog> {
  final ScrollController _scroll = ScrollController();
  late final List<_InstallItem> _items;
  int _current = 0;
  int _completed = 0;
  double _currentProgress = 0;
  bool _done = false;
  bool _stopAfterCurrent = false;
  OperationContext? _operation;
  // 标记是否有成功的安装，用于决定是否需要刷新列表
  bool _hasSuccess = false;
  DateTime _lastProgressPaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _items = widget.filePaths.map(_InstallItem.new).toList(growable: false);
    _start();
  }

  @override
  void dispose() {
    unawaited(_operation?.cancel(OperationCancelReason.requested));
    _scroll.dispose();
    super.dispose();
  }

  void _updateProgress(double value) {
    if (!mounted) return;
    final normalized = value.clamp(0.0, 1.0).toDouble();
    final now = DateTime.now();
    if (normalized < 1 &&
        now.difference(_lastProgressPaint) <
            const Duration(milliseconds: 100)) {
      return;
    }
    _lastProgressPaint = now;
    setState(() => _currentProgress = normalized);
  }

  void _requestStop() {
    if (_done) return;
    final operation = _operation;
    setState(() {
      _stopAfterCurrent = true;
      for (var i = _current + 1; i < _items.length; i++) {
        if (_items[i].status == _InstallStatus.queued) {
          _items[i].status = _InstallStatus.cancelled;
        }
      }
    });
    if (operation != null) {
      unawaited(operation.cancel(OperationCancelReason.requested));
    }
  }

  Future<void> _start() async {
    final state = context.read<AppState>();
    final serial = state.currentDevice;
    if (serial == null) {
      for (final item in _items) {
        item.status = _InstallStatus.failed;
        item.error = 'No target device selected.';
      }
      if (mounted) setState(() => _done = true);
      return;
    }

    final operation = state.adb.beginOperation(serial: serial);
    _operation = operation;
    try {
      for (int i = 0; i < widget.filePaths.length; i++) {
        if (!mounted) return;
        if (_stopAfterCurrent) break;

        setState(() {
          _current = i;
          _currentProgress = 0;
          _items[i].status = _InstallStatus.running;
        });

        // 自动滚动
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          _scroll.animateTo(
            (i * 48.0).clamp(0, _scroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        });

        String path = widget.filePaths[i];
        try {
          if (path.toLowerCase().endsWith('.xapk') ||
              path.toLowerCase().endsWith('.apks')) {
            await state.files.installXapk(
              path,
              serial: serial,
              onProgress: _updateProgress,
              operation: operation,
            );
          } else {
            await state.files.installApk(
              path,
              serial: serial,
              onProgress: _updateProgress,
              operation: operation,
            );
          }
          _hasSuccess = true;
          _items[i].status = _InstallStatus.succeeded;
        } catch (e) {
          if (operation.isCancelled) {
            _stopAfterCurrent = true;
            _items[i].status = _InstallStatus.cancelled;
            _items[i].error = 'Install cancelled.';
            state.addLog(
              "Install cancelled [${path.split(RegExp(r'[/\\]')).last}]",
            );
          } else {
            _items[i].status = _InstallStatus.failed;
            _items[i].error = e.toString();
            state.addLog(
              "Install Fail [${path.split(RegExp(r'[/\\]')).last}]: $e",
            );
          }
        } finally {
          if (mounted) {
            setState(() {
              _completed++;
              _currentProgress = 0;
            });
          }
        }
      }
    } finally {
      await operation.complete();
      if (identical(_operation, operation)) _operation = null;
    }

    if (mounted) {
      if (_stopAfterCurrent) {
        for (final item in _items) {
          if (item.status == _InstallStatus.queued) {
            item.status = _InstallStatus.cancelled;
          }
        }
      }
      setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Row(children: [
        if (!_done)
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
        if (!_done) const SizedBox(width: 12),
        Text(_done
            ? i18n.installDialogTitleDone
            : i18n.installDialogTitleInstalling),
      ]),
      content: SizedBox(
        width: 450,
        height: 350,
        child: Column(
          children: [
            LinearProgressIndicator(
              value: _items.isEmpty
                  ? 1
                  : (_completed + _currentProgress) / _items.length,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                i18n.installCompletedCount(_completed, _items.length),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemCount: _items.length,
                itemExtent: 48,
                itemBuilder: (ctx, index) =>
                    _InstallItemTile(item: _items[index]),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!_done)
          TextButton(
            onPressed: _stopAfterCurrent ? null : _requestStop,
            child: Text(i18n.installStopAfterCurrent),
          ),
        if (_done)
          FilledButton(
              // 返回 _hasSuccess 状态给上一级
              onPressed: () => Navigator.pop(context, _hasSuccess),
              child: Text(i18n.installDialogClose))
      ],
    );
  }
}

enum _InstallStatus { queued, running, succeeded, failed, cancelled }

class _InstallItem {
  final String path;
  _InstallStatus status = _InstallStatus.queued;
  String? error;

  _InstallItem(this.path);
}

class _InstallItemTile extends StatelessWidget {
  final _InstallItem item;

  const _InstallItemTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final name = item.path.split(RegExp(r'[/\\]')).last;
    final (icon, color) = switch (item.status) {
      _InstallStatus.queued => (Icons.schedule, Colors.grey),
      _InstallStatus.running => (Icons.downloading, Colors.blue),
      _InstallStatus.succeeded => (Icons.check_circle, Colors.green),
      _InstallStatus.failed => (
          Icons.error,
          Theme.of(context).colorScheme.error
        ),
      _InstallStatus.cancelled => (Icons.cancel, Colors.grey),
    };

    return Tooltip(
      message: item.error ?? name,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: color,
                  fontWeight: item.status == _InstallStatus.running
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
