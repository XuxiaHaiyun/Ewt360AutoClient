// 应用冒烟测试
//
// 验证 [EwtApp] 可正常构建并渲染登录页, 不抛异常。
// 不依赖账号配置, 离线可跑。
import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    // 模拟 SharedPreferences, 避免 tryRestoreSession 触达平台通道
    SharedPreferences.setMockInitialValues({});
    // 注册 getIt 依赖 (app_router 依赖 getIt<ProviderContainer>)
    configureDependencies();
    getIt.registerSingleton<ProviderContainer>(ProviderContainer());
  });

  testWidgets('App 渲染登录页', (WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: getIt<ProviderContainer>(),
      child: const EwtApp(),
    ));
    await tester.pumpAndSettle();

    // 登录页可见元素: 标题 + 登录按钮 (初始无账号 → 显示登录表单)
    expect(find.text('EWT Auto Client'), findsOneWidget);
    expect(find.text('登录'), findsWidgets);
    // 渲染过程无异常
    expect(tester.takeException(), isNull);
  });
}
