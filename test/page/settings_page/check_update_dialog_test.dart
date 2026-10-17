import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_download_monitor.dart';
import 'package:pure_music/page/settings_page/check_update.dart';

void main() {
  final info = UpdateInfo.fromJson({
    'tag_name': 'v9.9.9',
    'body': '说明',
    'installer_url':
        'https://github.com/junglecola001/Pure-music/releases/download/v9.9.9/app.exe',
    'installer_sha256': 'ab' * 32,
    'portable_url':
        'https://github.com/junglecola001/Pure-music/releases/download/v9.9.9/app.zip',
    'portable_sha256': 'cd' * 32,
    'portable_size': 1024,
  });

  setUp(UpdateDownloadMonitor.instance.reset);
  tearDown(UpdateDownloadMonitor.instance.reset);

  Future<void> pumpHarness(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: UpdateTitleStatus(),
              ),
              Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () {
                      showDialog<void>(
                        context: context,
                        builder: (context) => NewestUpdateView(
                          info: info,
                          channel: UpdateChannel.github,
                        ),
                      );
                    },
                    child: const Text('open'),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('tapping outside closes the update dialog before download', (
    tester,
  ) async {
    await pumpHarness(tester);
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('有新更新'), findsOneWidget);

    await tester.tapAt(const Offset(8, 8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('有新更新'), findsNothing);
  });

  testWidgets('tapping outside collapses the dialog and keeps the download', (
    tester,
  ) async {
    UpdateDownloadMonitor.instance.preview(
      phase: UpdateMonitorPhase.downloading,
      info: info,
      channel: UpdateChannel.github,
      received: 40,
      total: 100,
    );
    await pumpHarness(tester);
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('有新更新'), findsOneWidget);

    await tester.tapAt(const Offset(8, 8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('有新更新'), findsNothing);
    expect(find.text('正在下载更新 40%'), findsOneWidget);
    expect(
      UpdateDownloadMonitor.instance.phase,
      UpdateMonitorPhase.downloading,
    );

    await tester.tap(find.byTooltip('取消'));
    await tester.pump();

    expect(find.text('正在下载更新 40%'), findsNothing);
    expect(UpdateDownloadMonitor.instance.phase, UpdateMonitorPhase.idle);
  });

  testWidgets('ready status opens the dialog at install', (tester) async {
    UpdateDownloadMonitor.instance.preview(
      phase: UpdateMonitorPhase.ready,
      info: info,
      channel: UpdateChannel.github,
    );
    await pumpHarness(tester);
    await tester.pump();

    expect(find.text('更新已下载，点击安装'), findsOneWidget);
    expect(find.byTooltip('取消'), findsNothing);

    await tester.tap(find.text('更新已下载，点击安装'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('安装更新'), findsOneWidget);
    expect(find.text('有新更新'), findsOneWidget);
  });
}
