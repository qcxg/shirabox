import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/logcat_provider.dart';

class LogcatPage extends StatefulWidget {
  const LogcatPage({super.key});

  @override
  State<LogcatPage> createState() => _LogcatPageState();
}

class _LogcatPageState extends State<LogcatPage> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _filterController = TextEditingController();
  Timer? _filterDebounce;
  bool _initialized = false;
  bool _followTail = true;
  bool _tailJumpScheduled = false;
  int _lastRenderedRevision = -1;
  LogLevel _minimumLevel = LogLevel.verbose;
  LogcatFilterMode _filterMode = LogcatFilterMode.terms;
  bool _caseSensitive = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final provider = context.read<LogcatProvider>();
    _filterController.text = provider.filterText;
    _minimumLevel = provider.minLevel;
    _filterMode = provider.filterMode;
    _caseSensitive = provider.caseSensitive;
    _initialized = true;
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  void _queueFilterUpdate() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 180), _applyFilter);
  }

  void _applyFilter() {
    if (!mounted) return;
    context.read<LogcatProvider>().setFilter(
          query: _filterController.text,
          level: _minimumLevel,
          mode: _filterMode,
          matchCase: _caseSensitive,
        );
  }

  void _clearFilter() {
    _filterDebounce?.cancel();
    _filterController.clear();
    _applyFilter();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification &&
        notification is! UserScrollNotification) {
      return false;
    }
    // The list is reversed: offset zero is always the newest entry. This
    // avoids chasing a moving maxScrollExtent while Logcat is appending.
    final nearTail = notification.metrics.pixels <= 4;
    if (nearTail != _followTail) {
      setState(() => _followTail = nearTail);
    }
    return false;
  }

  void _resumeTail() {
    if (!_followTail) setState(() => _followTail = true);
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.minScrollExtent,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
    );
  }

  void _scheduleTailJump(int revision) {
    if (_lastRenderedRevision == revision) return;
    _lastRenderedRevision = revision;
    if (!_followTail || _tailJumpScheduled) return;
    _tailJumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tailJumpScheduled = false;
      if (!mounted || !_followTail || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.pixels > position.minScrollExtent + 0.5) {
        _scrollController.jumpTo(position.minScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _buildToolbar(theme, i18n),
          const SizedBox(height: 8),
          _buildStatusBar(theme, i18n),
          const SizedBox(height: 8),
          Expanded(child: _buildLogViewport(theme, i18n)),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme, AppLocalizations i18n) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _buildLevelDropdown(theme),
              const SizedBox(width: 8),
              Expanded(child: _buildSearchField(theme, i18n)),
              const SizedBox(width: 8),
              FilterChip(
                selected: _filterMode == LogcatFilterMode.regularExpression,
                label: Text(i18n.logcatRegex),
                avatar: const Icon(Icons.data_object, size: 16),
                onSelected: (selected) {
                  setState(() {
                    _filterMode = selected
                        ? LogcatFilterMode.regularExpression
                        : LogcatFilterMode.terms;
                  });
                  _applyFilter();
                },
              ),
              const SizedBox(width: 6),
              FilterChip(
                selected: _caseSensitive,
                label: Text(i18n.logcatCaseSensitive),
                avatar: const Icon(Icons.text_fields, size: 16),
                onSelected: (selected) {
                  setState(() => _caseSensitive = selected);
                  _applyFilter();
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.tips_and_updates_outlined,
                  size: 15, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  i18n.logcatFilterHelp,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildCaptureButton(theme, i18n),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: context.read<LogcatProvider>().clear,
                tooltip: i18n.logcatClear,
              ),
              _buildExportButton(i18n),
              IconButton(
                icon: Icon(
                  Icons.vertical_align_bottom_rounded,
                  color: _followTail ? theme.colorScheme.primary : null,
                ),
                onPressed: _resumeTail,
                tooltip: i18n.logcatBottom,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLevelDropdown(ThemeData theme) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LogLevel>(
          value: _minimumLevel,
          items: LogLevel.values
              .map(
                (level) => DropdownMenuItem<LogLevel>(
                  value: level,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: level.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text('${level.code}  ${level.name.toUpperCase()}'),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _minimumLevel = value);
            _applyFilter();
          },
        ),
      ),
    );
  }

  Widget _buildSearchField(ThemeData theme, AppLocalizations i18n) {
    return Selector<LogcatProvider, String?>(
      selector: (_, provider) => provider.filterError,
      builder: (context, filterError, child) {
        final borderColor = filterError == null
            ? theme.colorScheme.outlineVariant
            : theme.colorScheme.error;
        return TextField(
          controller: _filterController,
          onChanged: (_) => _queueFilterUpdate(),
          onSubmitted: (_) {
            _filterDebounce?.cancel();
            _applyFilter();
          },
          style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
          decoration: InputDecoration(
            hintText: i18n.logcatHint,
            prefixIcon: const Icon(Icons.manage_search, size: 19),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _filterController,
              builder: (context, value, child) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(Icons.close, size: 17),
                      onPressed: _clearFilter,
                    ),
            ),
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.35),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: filterError == null
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCaptureButton(ThemeData theme, AppLocalizations i18n) {
    return Selector<LogcatProvider, (bool, bool)>(
      selector: (_, provider) =>
          (provider.isRunning, provider.captureRequested),
      builder: (context, status, child) {
        final active = status.$1 || status.$2;
        return FilledButton.icon(
          onPressed: context.read<LogcatProvider>().toggleStart,
          style: FilledButton.styleFrom(
            backgroundColor:
                active ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
          icon: Icon(active ? Icons.stop : Icons.play_arrow, size: 18),
          label: Text(active ? i18n.logcatBtnStop : i18n.logcatBtnStart),
        );
      },
    );
  }

  Widget _buildExportButton(AppLocalizations i18n) {
    return Selector<LogcatProvider, bool>(
      selector: (_, provider) => provider.visibleCount > 0,
      builder: (context, hasLogs, child) => IconButton(
        icon: const Icon(Icons.download_rounded),
        onPressed: !hasLogs
            ? null
            : () async {
                final path = await context.read<LogcatProvider>().export(
                      dialogTitle: i18n.logcatExportTitle,
                    );
                if (path != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(i18n.logcatExportSaved(path))),
                  );
                }
              },
        tooltip: i18n.logcatExport,
      ),
    );
  }

  Widget _buildStatusBar(ThemeData theme, AppLocalizations i18n) {
    return Selector<LogcatProvider, (int, int, int, int, String?, String?)>(
      selector: (_, provider) => (
        provider.visibleCount,
        provider.retainedCount,
        provider.pendingCount,
        provider.droppedPendingLines,
        provider.filterError,
        provider.lastError,
      ),
      builder: (context, status, child) {
        final message = status.$5 != null
            ? i18n.logcatFilterInvalid(status.$5!)
            : status.$6;
        return Row(
          children: [
            Text(
              i18n.logcatStats(status.$1, status.$2, status.$3),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            if (status.$4 > 0) ...[
              const SizedBox(width: 12),
              Icon(Icons.warning_amber_rounded,
                  size: 15, color: theme.colorScheme.error),
              const SizedBox(width: 4),
              Text(
                i18n.logcatDropped(status.$4),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (message != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ] else
              const Spacer(),
          ],
        );
      },
    );
  }

  Widget _buildLogViewport(ThemeData theme, AppLocalizations i18n) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF202124),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Selector<LogcatProvider, (int, int)>(
          selector: (_, provider) =>
              (provider.logsRevision, provider.visibleCount),
          builder: (context, state, child) {
            _scheduleTailJump(state.$1);
            final entries = context.read<LogcatProvider>().logs;
            if (entries.isEmpty) {
              return Center(
                child: Text(
                  i18n.logcatNoMatches,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.45)),
                ),
              );
            }
            return Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    interactive: true,
                    child: ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      itemCount: entries.length,
                      itemExtent: 25,
                      cacheExtent: 25 * 24,
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: true,
                      itemBuilder: (context, index) {
                        final entry = entries[entries.length - 1 - index];
                        return _LogLine(entry: entry);
                      },
                    ),
                  ),
                ),
                if (!_followTail)
                  Positioned(
                    right: 18,
                    bottom: 18,
                    child: FilledButton.tonalIcon(
                      onPressed: _resumeTail,
                      icon: const Icon(Icons.south, size: 17),
                      label: Text(i18n.logcatResumeLive),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LogEntry entry;

  void _showDetail(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        surfaceTintColor: Colors.transparent,
        title: Row(
          children: [
            Icon(Icons.info_outline, color: entry.level.color, size: 20),
            const SizedBox(width: 10),
            Text(
              i18n.logcatDetailTitle,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        content: SizedBox(
          width: 680,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: SingleChildScrollView(
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _detailItem(i18n.logcatDetailTime, entry.time),
                    if (entry.pid != null)
                      _detailItem(i18n.logcatPid, entry.pid.toString()),
                    if (entry.tid != null)
                      _detailItem(i18n.logcatTid, entry.tid.toString()),
                    _detailItem(
                      i18n.logcatDetailLevel,
                      entry.level.name.toUpperCase(),
                      color: entry.level.color,
                    ),
                    _detailItem(
                      i18n.logcatDetailTag,
                      entry.tag,
                      color: entry.level.color.withValues(alpha: 0.85),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Divider(color: Colors.white10, height: 1),
                    ),
                    Text(
                      '${i18n.logcatDetailContent}:',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        entry.msg,
                        style: const TextStyle(
                          color: Color(0xFFEEEEEE),
                          fontFamily: 'Consolas',
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy_all, size: 18),
            label: Text(i18n.logcatCopyAll),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: entry.formattedLine));
              Navigator.pop(context);
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(i18n.logcatCopyContent),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: entry.msg));
              Navigator.pop(context);
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(i18n.installDialogClose),
          ),
        ],
      ),
    );
  }

  Widget _detailItem(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              '$label:',
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: color ?? Colors.white70,
                fontFamily: 'Consolas',
                fontSize: 13,
                fontWeight: color == null ? FontWeight.normal : FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final levelColor = entry.level.color;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showDetail(context),
        hoverColor: Colors.white.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: DefaultTextStyle(
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12.5,
              height: 1,
              color: Color(0xFFE0E0E0),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 140,
                  child: Text(
                    entry.time,
                    overflow: TextOverflow.clip,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                SizedBox(
                  width: 58,
                  child: Text(
                    entry.pid?.toString() ?? '',
                    textAlign: TextAlign.right,
                    style: const TextStyle(color: Colors.white30),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 18,
                  child: Text(
                    entry.level.code,
                    style: TextStyle(
                      color: levelColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 170,
                  child: Text(
                    entry.tag,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: levelColor.withValues(alpha: 0.82),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.msg,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: entry.level.index >= LogLevel.error.index
                          ? const Color(0xFFFFBABA)
                          : const Color(0xFFE0E0E0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
