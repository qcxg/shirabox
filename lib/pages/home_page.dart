import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
// 引入国际化
import '../l10n/app_localizations.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Timer? _refreshTimer;
  final ScrollController _logScrollCtrl = ScrollController();
  StreamSubscription? _logSubscription;
  bool _isLogExpanded = false;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
      if (mounted) {
        unawaited(context.read<AppState>().refreshSystemInfoOnly());
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      _logSubscription = appState.onLogAdded.listen((_) {
        if (!mounted) return;
        if (_logScrollCtrl.hasClients && !_isLogExpanded) {
          _logScrollCtrl.jumpTo(0);
        }
      });
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _logSubscription?.cancel();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdbValid = context.select<AppState, bool>((s) => s.isAdbValid);
    final isConnected = context.select<AppState, bool>((s) => s.isConnected);
    final i18n = AppLocalizations.of(context)!;

    if (!isAdbValid) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 80, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 24),
            Text(
              i18n.homeNoAdbTitle,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              i18n.homeNoAdbContent,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              onPressed: () {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(i18n.homeGoSettings)));
              },
              icon: const Icon(Icons.settings),
              label: Text(i18n.homeGoSettings),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () async {
                await context.read<AppState>().retryAdbConnection();
                if (!context.mounted) return;
                if (!context.read<AppState>().isAdbValid) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Check Failed")));
                }
              },
              icon: const Icon(Icons.refresh),
              label: Text(i18n.homeRetryCheck),
            )
          ],
        ),
      );
    }

    if (!isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.usb_off,
                size: 80, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(i18n.homeWaitDevice, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 8),
            Text(i18n.homeWaitHint, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            FilledButton.tonal(
                onPressed: () => context.read<AppState>().checkDevices(),
                child: Text(i18n.homeManualCheck))
          ],
        ),
      );
    }

    return Column(
      children: [
        // 仪表盘
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: const SingleChildScrollView(
              padding: EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DeviceHeader(),
                  SizedBox(height: 32),
                  _ResourceMonitor(),
                  SizedBox(height: 32),
                  Divider(),
                  SizedBox(height: 20),
                  _SystemInfoGrid(),
                  SizedBox(height: 32),
                  _QuickActions(),
                ],
              ),
            ),
          ),
        ),

        // 日志面板
        _LogPanel(
          isExpanded: _isLogExpanded,
          scrollController: _logScrollCtrl,
          onToggle: () => setState(() => _isLogExpanded = !_isLogExpanded),
        ),
      ],
    );
  }
}

// 日志面板 (暂不深度汉化，因为Log内容本身是技术性的)
class _LogPanel extends StatelessWidget {
  final bool isExpanded;
  final ScrollController scrollController;
  final VoidCallback onToggle;

  const _LogPanel({
    required this.isExpanded,
    required this.scrollController,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final logText = context.select<AppState, String>((s) => s.logText);
    final totalHeight = MediaQuery.of(context).size.height * 0.6;
    final i18n = AppLocalizations.of(context)!;

    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutQuad,
        height: isExpanded ? totalHeight : 140,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          border: Border(
              top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant)),
          boxShadow: [
            if (isExpanded)
              BoxShadow(
                  // 修复: deprecated withOpacity
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -5))
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            InkWell(
              onTap: onToggle,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.transparent,
                child: Row(
                  children: [
                    const Icon(Icons.history_edu, size: 16, color: Colors.grey),
                    const SizedBox(width: 8),
                    // 这里引用了 i18n.navLogs ("日志") + "Console"
                    Text("${i18n.navLogs} Console",
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey)),
                    const Spacer(),
                    Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                        size: 20),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: OverflowBox(
                minHeight: totalHeight - 40,
                maxHeight: totalHeight - 40,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      logText,
                      style: const TextStyle(
                          fontFamily: 'Consolas', fontSize: 12, height: 1.4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingChart extends StatefulWidget {
  final String title;
  final double value;
  final String text;
  final Color color;
  final bool showSubText;

  const _RingChart(
      {required this.title,
      required this.value,
      required this.text,
      required this.color,
      this.showSubText = true});

  @override
  State<_RingChart> createState() => _RingChartState();
}

class _RingChartState extends State<_RingChart> {
  double _lastValidValue = 0.0;

  @override
  void didUpdateWidget(covariant _RingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value > 0) {
      _lastValidValue = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayValue = widget.value > 0 ? widget.value : _lastValidValue;

    return Column(children: [
      SizedBox(
          width: 80,
          height: 80,
          child: Stack(fit: StackFit.expand, children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: displayValue.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (context, val, _) {
                return CircularProgressIndicator(
                    value: val,
                    strokeWidth: 6,
                    // 修复
                    backgroundColor: widget.color.withValues(alpha: 0.1),
                    color: widget.color,
                    strokeCap: StrokeCap.round);
              },
            ),
            Center(
                child: Text("${(displayValue * 100).toInt()}%",
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)))
          ])),
      const SizedBox(height: 8),
      Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w500)),
      if (widget.showSubText)
        Text(widget.text,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ]);
  }
}

class _DeviceHeader extends StatelessWidget {
  const _DeviceHeader();
  @override
  Widget build(BuildContext context) {
    final deviceDetail =
        context.select<AppState, Map<String, String>>((s) => s.deviceDetail);
    final serial = context.select<AppState, String?>((s) => s.currentDevice);
    final i18n = AppLocalizations.of(context)!;

    // 判斷是否為無線連結 (IP:Port 格式)
    final bool isWireless =
        serial != null && RegExp(r'^\d+\.\d+\.\d+\.\d+:\d+$').hasMatch(serial);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.phone_android,
              size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 20),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                        "${deviceDetail['brand'] ?? ''} ${deviceDetail['model'] ?? 'Unknown'}",
                        style: Theme.of(context).textTheme.headlineMedium,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (isWireless) ...[
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: Colors.grey.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.wifi_tethering,
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              i18n.wirelessWarning,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.qr_code, size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Text("SN: $serial", style: const TextStyle(color: Colors.grey))
              ]),
            ]),
          ),
        ]),
      ],
    );
  }
}

class _ResourceMonitor extends StatelessWidget {
  const _ResourceMonitor();
  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;
    return RepaintBoundary(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Selector<AppState, Map<String, dynamic>>(
            selector: (_, s) => s.cpuInfo,
            builder: (_, info, __) => _RingChart(
                title: i18n.homeTabCpu, // "CPU"
                value: info['ratio'] ?? 0.0,
                text: info['text'] ?? '0%',
                color: Colors.redAccent,
                showSubText: false),
          ),
          Selector<AppState, Map<String, dynamic>>(
            selector: (_, s) => s.ramInfo,
            builder: (_, info, __) => _RingChart(
                title: i18n.homeTabRam, // "内存"
                value: info['ratio'] ?? 0.0,
                text: info['text'] ?? '- / -',
                color: Colors.blueAccent),
          ),
          Selector<AppState, Map<String, dynamic>>(
            selector: (_, s) => s.storageInfo,
            builder: (_, info, __) => _RingChart(
                title: i18n.homeTabStorage, // "存储"
                value: info['ratio'] ?? 0.0,
                text: info['text'] ?? '- / -',
                color: Colors.orangeAccent),
          ),
        ],
      ),
    );
  }
}

class _SystemInfoGrid extends StatelessWidget {
  const _SystemInfoGrid();
  @override
  Widget build(BuildContext context) {
    final detail =
        context.select<AppState, Map<String, String>>((s) => s.deviceDetail);
    final kernel = context.select<AppState, String>((s) => s.kernelVersion);
    final i18n = AppLocalizations.of(context)!;

    return Wrap(spacing: 16, runSpacing: 16, children: [
      _InfoBox(
          title: "Android",
          value: detail['android'] ?? '-',
          icon: Icons.android),
      _InfoBox(title: "SDK", value: detail['sdk'] ?? '-', icon: Icons.api),
      _InfoBox(
          title: i18n.homeItemKernel, // "内核"
          value: kernel,
          icon: Icons.developer_board,
          isWide: true),
    ]);
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();
  @override
  Widget build(BuildContext context) {
    final show = context.select<AppState, bool>((s) => s.showQuickBoot);
    final commands =
        context.select<AppState, List<dynamic>>((s) => s.quickCommands);
    final i18n = AppLocalizations.of(context)!;

    if (!show || commands.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(i18n.homeQuickBoot, // "快捷启动"
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: 16),
      Wrap(
          spacing: 16,
          runSpacing: 16,
          children: commands.map((cmd) {
            return FilledButton.tonalIcon(
                onPressed: () => context.read<AppState>().runQuickCommand(cmd),
                icon: const Icon(Icons.rocket_launch),
                label: Text(cmd.name));
          }).toList()),
    ]);
  }
}

class _InfoBox extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final bool isWide;
  const _InfoBox(
      {required this.title,
      required this.value,
      required this.icon,
      this.isWide = false});
  @override
  Widget build(BuildContext context) {
    return Container(
        width: isWide ? 260 : 120,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            // 修复
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.5))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(title,
                style: const TextStyle(fontSize: 12, color: Colors.grey))
          ]),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis)
        ]));
  }
}
