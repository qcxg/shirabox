import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shirabox/l10n/app_localizations.dart';
import 'package:shirabox/pages/logcat_page.dart';
import 'package:shirabox/providers/logcat_provider.dart';
import 'package:shirabox/services/adb_core.dart';
import 'package:shirabox/services/adb_process.dart';

void main() {
  testWidgets('renders a burst, pauses away from tail, and resumes at zero',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _WidgetLogcatService();
    final provider = LogcatProvider(
      source,
      flushInterval: const Duration(milliseconds: 10),
      maxLinesPerFlush: 1000,
    );
    addTearDown(() async {
      provider.dispose();
      await source.disposeSource();
    });
    provider.handleDeviceChange('device-a');
    provider.startCapture();
    for (var index = 0; index < 200; index++) {
      source.add(
        '07-19 12:34:56.789  ${1000 + index}  ${2000 + index} '
        'I ${index == 199 ? 'Special' : 'Bulk'}: message $index',
      );
    }

    await tester.pumpWidget(
      ChangeNotifierProvider<LogcatProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: LogcatPage()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));

    expect(find.text('message 199'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final listView = tester.widget<ListView>(find.byType(ListView));
    final scrollController = listView.controller!;
    scrollController.jumpTo(200);
    await tester.pump();

    expect(find.text('Resume live tail'), findsOneWidget);
    await tester.tap(find.text('Resume live tail'));
    await tester.pumpAndSettle();
    expect(scrollController.position.pixels, closeTo(0, 0.1));
    expect(find.text('Resume live tail'), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'tag:Special',
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(provider.visibleCount, 1);
    expect(find.text('message 199'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _WidgetLogcatService extends AdbProcessService {
  _WidgetLogcatService() : super(AdbCore(checkOnCreate: false));

  final StreamController<String> _controller =
      StreamController<String>(sync: true);

  void add(String line) => _controller.add(line);

  @override
  Stream<String> startLogcat({String? filter, String? serial}) {
    return _controller.stream;
  }

  @override
  Future<void> stopLogcat() async {}

  Future<void> disposeSource() => _controller.close();
}
