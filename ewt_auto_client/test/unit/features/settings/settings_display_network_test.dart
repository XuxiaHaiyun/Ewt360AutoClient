/// 设置页新增项 (网络调优 / 显示个性化) 单元测试 (SharedPreferences mock)
///
/// 覆盖: 持久化往返 / 运行时生效 (NetworkTuning) / 导入字体 JSON /
/// AppTheme 字体与过渡动画注入。
library;

import 'dart:io';

import 'package:ewt_auto_client/core/fonts/font_manager.dart';
import 'package:ewt_auto_client/core/network/network_tuning.dart';
import 'package:ewt_auto_client/core/theme/app_theme.dart';
import 'package:ewt_auto_client/features/settings/presentation/providers/settings_provider.dart';
import 'package:flutter/material.dart' show TargetPlatform;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NetworkTuning.update(
      trustAll: false,
      http2: false,
      retryCount: 0,
      retryIntervalMs: 1000,
    );
  });

  Future<AppSettingsNotifier> buildNotifier(ProviderContainer container) async {
    final notifier = container.read(appSettingsProvider.notifier);
    await pumpEventQueue();
    return notifier;
  }

  group('网络调优设置', () {
    test('持久化往返 + NetworkTuning 同步生效', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('settings_disableSslVerify', true);
      await prefs.setBool('settings_enableHttp2', true);
      await prefs.setInt('settings_connectRetryCount', 3);
      await prefs.setInt('settings_connectRetryIntervalMs', 2000);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = await buildNotifier(container);

      final s = container.read(appSettingsProvider);
      expect(s.disableSslVerify, isTrue);
      expect(s.enableHttp2, isTrue);
      expect(s.connectRetryCount, 3);
      expect(s.connectRetryIntervalMs, 2000);
      expect(NetworkTuning.trustAllCerts, isTrue, reason: '启动加载同步运行时');
      expect(NetworkTuning.enableHttp2, isTrue);
      expect(NetworkTuning.connectRetryCount, 3);
      expect(NetworkTuning.connectRetryIntervalMs, 2000);

      // setter 实时生效
      await notifier.setDisableSslVerify(false);
      await notifier.setConnectRetryCount(5);
      expect(NetworkTuning.trustAllCerts, isFalse);
      expect(NetworkTuning.connectRetryCount, 5);

      // 重新加载一致
      await notifier.setDisableSslVerify(true);
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      await buildNotifier(container2);
      expect(container2.read(appSettingsProvider).disableSslVerify, isTrue);
      expect(NetworkTuning.trustAllCerts, isTrue);
    });
  });

  group('显示个性化设置', () {
    test('悬浮底栏/界面缩放/过渡动画持久化往返', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = await buildNotifier(container);

      await notifier.setFloatingBottomBar(true);
      await notifier.setUiScale(1.25);
      await notifier.setPageTransition('fade');
      await pumpEventQueue(); // 等待 _persist 完成, 避免 teardown dispose 竞争

      final s = container.read(appSettingsProvider);
      expect(s.floatingBottomBar, isTrue);
      expect(s.uiScale, 1.25);
      expect(s.pageTransition, 'fade');
      expect(s.appFontFamily, isNull, reason: '默认字体返回 null 跟随主题');
    });

    test('导入字体 JSON 往返 + 字体选择/移除回退', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = await buildNotifier(container);

      const font = ImportedFont(family: 'MyFont', path: '/fonts/MyFont.ttf');
      final back = ImportedFont.fromJson(font.toJson());
      expect(back.family, 'MyFont');
      expect(back.path, '/fonts/MyFont.ttf');

      // registerFamily 需要真实字体字节: 用内置字体资产生成临时文件
      final data = await rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf');
      final tmpDir = await Directory.systemTemp.createTemp('ewt_font_test');
      addTearDown(() async {
        try {
          await tmpDir.delete(recursive: true);
        } catch (_) {}
      });
      final realFont = ImportedFont(
        family: 'MyFont',
        path: '${tmpDir.path}/MyFont.ttf',
      );
      await File(realFont.path).writeAsBytes(
        data.buffer.asUint8List(),
        flush: true,
      );

      await notifier.addImportedFont(realFont);
      await notifier.setAppFont(kind: 'imported', value: 'MyFont');
      await pumpEventQueue();
      var s = container.read(appSettingsProvider);
      expect(s.appFontKind, 'imported');
      expect(s.appFontFamily, 'MyFont');

      // 移除正在使用的字体 → 回退默认
      await notifier.removeImportedFont(realFont);
      s = container.read(appSettingsProvider);
      expect(s.importedFonts, isEmpty);
      expect(s.appFontKind, 'default');
      expect(s.appFontFamily, isNull);
    });

    test('AppTheme 注入全局字体与页面过渡动画', () {
      final themed = AppTheme.light(
        null,
        fontFamily: 'MyFont',
        pageTransition: 'none',
      );
      expect(themed.textTheme.bodyLarge?.fontFamily, 'MyFont');
      expect(
        themed.pageTransitionsTheme.builders[TargetPlatform.android],
        isNotNull,
      );

      // native 默认: 字体不覆盖 (平台默认为 Roboto), 过渡走 Flutter 默认
      final native = AppTheme.light(null);
      expect(native.textTheme.bodyLarge?.fontFamily, isNot('MyFont'));
    });
  });
}
