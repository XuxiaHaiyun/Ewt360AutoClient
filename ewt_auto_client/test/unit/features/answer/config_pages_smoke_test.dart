/// 配置页面冒烟测试 (窄屏 + 宽屏布局)
///
/// 覆盖弹窗转页面改造后的三个配置页:
///   - [ReportConfigPage] 进度上报配置页 (含各上报模式切换)
///   - [AnswerConfigPage] 试题答案配置页
///   - [WeekendAnswerConfigPage] 周培优答案配置页
///
/// 验证页面可在不同宽度下构建, 核心控件存在且确认操作返回配置。
library;

import 'package:ewt_auto_client/features/answer/domain/entities/answer_config.dart';
import 'package:ewt_auto_client/features/answer/presentation/pages/answer_config_page.dart';
import 'package:ewt_auto_client/features/player/domain/entities/report_config.dart';
import 'package:ewt_auto_client/features/player/presentation/pages/report_config_page.dart';
import 'package:ewt_auto_client/features/weekend/presentation/pages/weekend_answer_config_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('ReportConfigPage 布局冒烟', () {
    testWidgets('窄屏单列: 构建成功且包含模式/类型/学科/心跳等配置项', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ReportConfigPage())),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ReportConfigPage), findsOneWidget);
      expect(find.text('上报模式'), findsWidgets);
      expect(find.text('上报课程类型（至少选择一项）'), findsOneWidget);
      expect(find.text('上报课程学科（至少选择一项）'), findsOneWidget);
      expect(find.text('心跳时间（秒）'), findsOneWidget);
      expect(find.text('并行执行模式'), findsOneWidget);
      // 快刷参数在普通模式下不显示
      expect(find.text('快刷参数'), findsNothing);
      // 注入分区默认隐藏 (设置页高级栏开关控制)
      expect(find.text('任意用户进度注入'), findsNothing);
    });

    testWidgets('宽屏双栏: 模式在左栏, 参数在右栏', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ReportConfigPage())),
      );
      await tester.pumpAndSettle();

      expect(find.text('上报课程类型（至少选择一项）'), findsOneWidget);
      expect(find.text('心跳时间（秒）'), findsOneWidget);
    });

    testWidgets('模式切换到快刷2: 显示 session 数参数', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ReportConfigPage())),
      );
      await tester.pumpAndSettle();

      // 打开模式下拉并选择快刷模式2
      await tester.tap(find.text('正常模式').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('快刷模式2').last);
      await tester.pumpAndSettle();

      expect(find.text('session 数（多会话预算乘法）'), findsOneWidget);
      expect(find.text('快刷参数'), findsOneWidget);
    });

    testWidgets('确认操作返回当前模式配置', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ReportConfig? popped;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  popped = await ReportConfigPage.show(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportConfigPage), findsOneWidget);

      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(popped, isA<ReportConfig>());
      expect(find.byType(ReportConfigPage), findsNothing);
    });

    testWidgets('V7 注入开关: 打开显示 userid 输入框, 空目标时确认被拦截', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 设置页高级栏打开"任意用户进度注入"显示开关
      SharedPreferences.setMockInitialValues({
        'settings_showReportInject': true,
      });
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ReportConfigPage())),
      );
      await tester.pumpAndSettle();

      expect(find.text('任意用户进度注入'), findsOneWidget);
      expect(find.text('目标 userid'), findsNothing);

      // 打开注入开关 (与"任意用户进度注入"同一 Row 内的 Switch, 位于参数区末尾需先滚动)
      final injectRow = find.ancestor(
        of: find.text('任意用户进度注入'),
        matching: find.byType(Row),
      ).first;
      final injectSwitch =
          find.descendant(of: injectRow, matching: find.byType(Switch));
      await tester.ensureVisible(injectSwitch);
      await tester.pumpAndSettle();
      await tester.tap(injectSwitch);
      await tester.pumpAndSettle();
      expect(find.text('目标 userid'), findsOneWidget);

      // 未填 userid 时确认 → 弹提示且页面不关闭
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('已开启任意用户进度注入, 请填写目标 userid'), findsOneWidget);
      expect(find.byType(ReportConfigPage), findsOneWidget);

      // 填入目标 userid → 确认后正常返回
      final targetField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '纯数字 userid',
      );
      expect(targetField, findsOneWidget);
      await tester.ensureVisible(targetField);
      await tester.pumpAndSettle();
      await tester.enterText(targetField, '161621588');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportConfigPage), findsNothing);
    });
  });

  group('AnswerConfigPage 布局冒烟', () {
    testWidgets('窄屏单列: 方案/展示内容/过滤/完成操作齐全', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AnswerConfigPage()));
      await tester.pumpAndSettle();

      expect(find.text('选择获取方案'), findsOneWidget);
      expect(find.text('展示内容'), findsOneWidget);
      expect(find.text('过滤选项'), findsOneWidget);
      expect(find.text('获取完成操作'), findsOneWidget);
      // 默认无操作: 提交配置不显示
      expect(find.text('提交配置'), findsNothing);
    });

    testWidgets('选择提交作答结果后显示提交配置', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AnswerConfigPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('提交作答结果'));
      await tester.pumpAndSettle();

      expect(find.text('提交配置'), findsOneWidget);
      expect(find.text('图片上传 (主观题)'), findsOneWidget);
    });
  });

  group('WeekendAnswerConfigPage 布局冒烟', () {
    testWidgets('窄屏: 仅方案与展示内容, 无过滤选项', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: WeekendAnswerConfigPage()));
      await tester.pumpAndSettle();

      expect(find.text('选择获取方案'), findsOneWidget);
      expect(find.text('展示内容'), findsOneWidget);
      expect(find.text('过滤选项'), findsNothing);
    });

    testWidgets('宽屏双栏: 方案与展示内容并排', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: WeekendAnswerConfigPage()));
      await tester.pumpAndSettle();

      expect(find.text('选择获取方案'), findsOneWidget);
      expect(find.text('原题目'), findsOneWidget);
    });

    testWidgets('开始获取返回默认配置', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      AnswerConfig? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                popped = await WeekendAnswerConfigPage.show(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('开始获取'));
      await tester.pumpAndSettle();

      expect(popped, isNotNull);
      expect(popped!.method, AnswerMethod.auto);
      expect(find.byType(WeekendAnswerConfigPage), findsNothing);
    });
  });

  group('ReportConfigPage 重刷模式 (基于普通模式)', () {
    /// 打开配置页, 选择指定模式; [beforeConfirm] 在点确认前执行 (可断言 UI),
    /// 确认后返回返回的配置
    Future<ReportConfig?> openAndPickMode(
      WidgetTester tester,
      String modeLabel, {
      void Function()? beforeConfirm,
    }) async {
      ReportConfig? popped;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () async {
                      popped = await ReportConfigPage.show(context);
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 上报模式为 DropdownMenu, 先展开下拉再选
      await tester.tap(find.byType(DropdownMenu<ReportMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(modeLabel).last);
      await tester.pumpAndSettle();

      beforeConfirm?.call();

      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      return popped;
    }

    testWidgets('切换重刷模式: 隐藏快刷参数区, 确认返回普通基准配置', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});

      // 切换到重刷模式, 确认前断言 UI
      final popped = await openAndPickMode(
        tester,
        '重刷模式',
        beforeConfirm: () {
          // 描述改为基于普通模式; 快刷参数区隐藏, 重刷参数区显示
          expect(find.textContaining('基于普通模式行为链'), findsOneWidget);
          expect(find.text('快刷参数'), findsNothing);
          expect(find.text('重刷参数（刷时长）'), findsOneWidget);
        },
      );

      // 确认 → 返回配置: rebrush 开, 快刷关, 其余为普通模式默认
      expect(popped, isA<ReportConfig>());
      expect(popped!.rebrush, isTrue);
      expect(popped.fastBrush, isFalse);
      expect(popped.fastBrush2, isFalse);
      expect(popped.speed, 1.0);
      expect(popped.heartbeatInterval, 60);
      expect(popped.rebrushRounds, 1);
      expect(popped.rebrushExtraMinutes, 60);
      expect(popped.completionThreshold, 0.8);
    });

    testWidgets('快刷/快刷2 默认完成阈值统一 80% (不再出现 81%/100%)', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      for (final label in ['快刷模式', '快刷模式2']) {
        SharedPreferences.setMockInitialValues({});
        final popped = await openAndPickMode(tester, label);
        expect(popped, isA<ReportConfig>(), reason: label);
        expect(popped!.fastBrush, isTrue, reason: label);
        expect(popped.completionThreshold, 0.8, reason: label);
      }
    });
  });
}
