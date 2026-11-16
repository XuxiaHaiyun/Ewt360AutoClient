// 视觉验收截图生成 (非断言测试)
//
// 渲染设置页在窄屏/宽屏/深色/强调色切换/强调色弹窗下的截图,
// 输出到 build/visual/*.png 供视觉验收使用。
// 字体: 加载系统微软雅黑, 避免测试环境 Ahem 字块影响验收。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/theme/app_theme.dart';
import 'package:ewt_auto_client/features/settings/presentation/pages/settings_page.dart';
import 'package:ewt_auto_client/features/settings/presentation/providers/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _outDir = 'build/visual';
const _testFontFamily = 'VisualTestFont';
const _captureKey = ValueKey('visual_capture_root');

void main() {
  setUpAll(() async {
    // 加载系统中文语系字体 (微软雅黑), 截图文字可读
    try {
      final bytes = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
      final loader = FontLoader(_testFontFamily)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {
      // 字体加载失败时退化 Ahem, 不阻塞
    }
    // 加载 MaterialIcons 字体 (位于 Flutter SDK 缓存), 图标可读
    try {
      // flutter_tester 位于 <sdk>/bin/cache/artifacts/engine/<arch>/,
      // 图标字体在 <sdk>/bin/cache/artifacts/material_fonts/
      final exe = File(Platform.resolvedExecutable).parent.path;
      final iconFont = File(
        '$exe/../../material_fonts/MaterialIcons-Regular.otf',
      );
      if (iconFont.existsSync()) {
        final bytes = await iconFont.readAsBytes();
        final loader = FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.view(bytes.buffer)));
        await loader.load();
      }
    } catch (_) {
      // 加载失败时图标显示为占位方块, 不阻塞
    }
    SharedPreferences.setMockInitialValues({});
    configureDependencies();
  });

  Future<void> pumpHarness(
    WidgetTester tester, {
    required Size size,
    ThemeMode themeMode = ThemeMode.light,
    Color? accent,
  }) async {
    final dpr = 2.0;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = size * dpr;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    getIt.registerSingleton<ProviderContainer>(container);
    addTearDown(() {
      container.dispose();
      if (getIt.isRegistered<ProviderContainer>()) {
        getIt.unregister<ProviderContainer>();
      }
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: _captureKey,
          child: Consumer(
            builder: (context, ref, _) {
              final settings = ref.watch(appSettingsProvider);
              var theme = AppTheme.light(accent ?? settings.accentColor);
              var dark = AppTheme.dark(accent ?? settings.accentColor);
              // 测试环境专用字体替换, 保证截图可读
              // (dialogTheme.titleTextStyle 独立于 textTheme, 需一并替换)
              theme = theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: _testFontFamily),
                dialogTheme: theme.dialogTheme.copyWith(
                  titleTextStyle: theme.dialogTheme.titleTextStyle?.copyWith(
                    fontFamily: _testFontFamily,
                  ),
                ),
              );
              dark = dark.copyWith(
                textTheme: dark.textTheme.apply(fontFamily: _testFontFamily),
                dialogTheme: dark.dialogTheme.copyWith(
                  titleTextStyle: dark.dialogTheme.titleTextStyle?.copyWith(
                    fontFamily: _testFontFamily,
                  ),
                ),
              );
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                darkTheme: dark,
                themeMode: themeMode,
                home: const SettingsPage(),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    // 图像编码需要真实异步, 在 FakeAsync 环境必须经 runAsync 执行
    final image = await tester.runAsync(
      () => boundary.toImage(pixelRatio: 2.0),
    );
    ByteData? bytes;
    if (image != null) {
      bytes = await tester.runAsync<ByteData?>(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
    }
    if (bytes == null) fail('截图编码失败');
    final dir = Directory(_outDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$_outDir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
  }

  void resetView(WidgetTester tester) {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(800, 600);
  }

  testWidgets('窄屏设置页 (手机竖屏, 单列)', (tester) async {
    await pumpHarness(tester, size: const Size(400, 860));
    await capture(tester, 'settings_narrow_light');
    resetView(tester);
  });

  testWidgets('宽屏设置页 (桌面, 双栏)', (tester) async {
    await pumpHarness(tester, size: const Size(1440, 900));
    await capture(tester, 'settings_wide_light');
    resetView(tester);
  });

  testWidgets('宽屏强调色弹窗', (tester) async {
    await pumpHarness(tester, size: const Size(1440, 900));
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();
    await capture(tester, 'settings_accent_dialog');
    resetView(tester);
  });

  testWidgets('宽屏极光紫强调色生效', (tester) async {
    final purple = AppTheme.accentPresets
        .firstWhere((p) => p.name == '极光紫')
        .color;
    await pumpHarness(tester, size: const Size(1440, 900), accent: purple);
    await capture(tester, 'settings_wide_purple');
    resetView(tester);
  });

  testWidgets('窄屏深色模式', (tester) async {
    await pumpHarness(
      tester,
      size: const Size(400, 860),
      themeMode: ThemeMode.dark,
    );
    await capture(tester, 'settings_narrow_dark');
    resetView(tester);
  });
}
