// 设置页强调色功能测试
//
// 验证:
// 1. 强调色 ListTile 显示当前选中预设名 (默认品牌蓝)
// 2. 弹窗选择新强调色后立即生效 (MaterialApp 种子色切换) 并回显
// 3. 选择结果持久化到 SharedPreferences (AppTheme.accentColorPrefKey)
import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/theme/app_theme.dart';
import 'package:ewt_auto_client/features/settings/presentation/pages/settings_page.dart';
import 'package:ewt_auto_client/features/settings/presentation/providers/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    // 模拟 SharedPreferences, 避免触达平台通道
    SharedPreferences.setMockInitialValues({});
    // 注册 getIt 依赖 (设置页 provider 依赖 DioClient 等)
    configureDependencies();
  });

  Future<ProviderContainer> pumpHarness(WidgetTester tester) async {
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
        child: Consumer(
          builder: (context, ref, _) {
            final settings = ref.watch(appSettingsProvider);
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(settings.accentColor),
              darkTheme: AppTheme.dark(settings.accentColor),
              themeMode: settings.themeMode,
              home: const SettingsPage(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('强调色默认显示品牌蓝', (tester) async {
    await pumpHarness(tester);

    // 强调色入口存在, 副标题为当前预设名
    expect(find.text('强调色'), findsOneWidget);
    expect(find.text('品牌蓝'), findsOneWidget);
    // 渲染过程无异常
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择极光紫后主题即时切换并持久化', (tester) async {
    await pumpHarness(tester);
    final purple = AppTheme.accentPresets
        .firstWhere((p) => p.name == '极光紫')
        .color;

    // 打开强调色弹窗
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();
    // 弹窗内列出全部预设, 且当前选中项 (品牌蓝) 带对勾
    expect(find.text('品牌蓝'), findsNWidgets(2)); // 弹窗项 + 页面副标题
    expect(find.byIcon(Icons.check), findsOneWidget);

    // 选择极光紫 → 弹窗关闭
    await tester.tap(find.text('极光紫'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsNothing);

    // 页面副标题回显新预设名
    expect(find.text('极光紫'), findsOneWidget);

    // 主题种子色已切换: 页面 primary 与该种子生成的方案一致
    final context = tester.element(find.text('强调色'));
    expect(
      Theme.of(context).colorScheme.primary,
      AppTheme.light(purple).colorScheme.primary,
    );

    // 持久化: accentColorPrefKey 写入所选颜色
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(AppTheme.accentColorPrefKey), purple.toARGB32());
  });

  testWidgets('已保存的强调色在下次构建时恢复', (tester) async {
    final purple = AppTheme.accentPresets
        .firstWhere((p) => p.name == '极光紫')
        .color;
    SharedPreferences.setMockInitialValues({
      AppTheme.accentColorPrefKey: purple.toARGB32(),
    });

    await pumpHarness(tester);

    expect(find.text('极光紫'), findsOneWidget);
    final context = tester.element(find.text('强调色'));
    expect(
      Theme.of(context).colorScheme.primary,
      AppTheme.light(purple).colorScheme.primary,
    );
  });
}
