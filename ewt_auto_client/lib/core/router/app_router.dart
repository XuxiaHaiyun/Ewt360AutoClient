/// go_router 应用路由: 声明式路由 + 登录态 redirect (监听 authProvider),
/// 主页面走 AdaptiveScaffold ShellRoute, 全屏页面挂在 root navigator。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey, NavigatorState;
import 'package:go_router/go_router.dart';

import '../../features/answer/domain/entities/question_info.dart';
import '../../features/answer/domain/entities/handwriting_config.dart';
import '../../features/answer/domain/entities/answer_config.dart';
import '../../features/answer/presentation/pages/answer_result_page.dart';
import '../../features/answer/presentation/pages/handwriting_config_page.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/home/presentation/pages/home_page.dart';
import '../../features/homework/presentation/pages/homework_list_page.dart';
import '../../features/weekend/presentation/pages/weekend_page.dart';
import '../../features/weekend/presentation/pages/book_list_page.dart';
import '../../features/settings/presentation/pages/settings_page.dart';
import '../../features/settings/presentation/pages/changelog_page.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../di/injection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 将 Riverpod Provider 变化转为 GoRouter 可监听的 Listenable
class _GoRouterRefreshStream extends ChangeNotifier {
  late final ProviderSubscription<AuthState> _sub;

  _GoRouterRefreshStream(ProviderContainer container) {
    _sub = container.listen(authProvider, (_, _) {
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

/// 全局根 Navigator key
///
/// 供服务层在无 BuildContext 时弹出全局对话框 (如 Web 端 ffmpeg.wasm
/// 组件下载进度弹窗), 挂在 GoRouter 根 Navigator 上。
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 应用路由配置
///
/// 使用 GoRouter 实现声明式路由，支持 Web deep link
final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/login',
  refreshListenable: _GoRouterRefreshStream(getIt<ProviderContainer>()),
  redirect: (context, state) {
    final container = getIt<ProviderContainer>();
    final authState = container.read(authProvider);
    final isAuthenticated = authState is AuthAuthenticated;
    final isOnLogin = state.matchedLocation == '/login';

    if (isAuthenticated && isOnLogin) return '/home';
    if (!isAuthenticated && !isOnLogin) return '/login';
    return null;
  },
  routes: [
    GoRoute(
      path: '/login',
      name: 'login',
      builder: (context, state) => const LoginPage(),
    ),
    ShellRoute(
      builder: (context, state, child) => AdaptiveScaffold(child: child),
      routes: [
        GoRoute(
          path: '/home',
          name: 'home',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: HomePage(),
          ),
        ),
        GoRoute(
          path: '/tasks',
          name: 'tasks',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: HomeworkListPage(),
          ),
        ),
        GoRoute(
          path: '/weekend',
          name: 'weekend',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: WeekendPage(),
          ),
        ),
        GoRoute(
          path: '/settings',
          name: 'settings',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: SettingsPage(),
          ),
        ),
      ],
    ),
    GoRoute(
      path: '/changelog',
      name: 'changelog',
      builder: (context, state) => const ChangelogPage(),
    ),
    // 教材库: 独立全屏页面, 放在 ShellRoute 外层 (root navigator)。
    // 由 context.push('/book-list') 打开, 覆盖侧栏/底部导航, 自带返回箭头;
    // 避免作为 ShellRoute 子路由时出现侧栏高亮到首页、返回退回周培优的问题。
    GoRoute(
      path: '/book-list',
      name: 'book-list',
      builder: (context, state) => const BookListPage(),
    ),
    // 答案展示页: 放在 ShellRoute 外层, 使用 root navigator
    // 避免覆盖底部导航栏 (ShellRoute 的子 navigator 会被遮挡)
    GoRoute(
      path: '/answer-result',
      name: 'answer-result',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final results = (extra?['results'] as List<CourseAnswerResult>?) ?? [];
        final displayConfig =
            extra?['displayConfig'] as AnswerConfig? ?? const AnswerConfig();
        return AnswerResultPage(
          results: results,
          displayConfig: displayConfig,
        );
      },
    ),
    // 手写模拟配置页: 独立页面 (非弹窗), 使用 root navigator
    GoRoute(
      path: '/handwriting-config',
      name: 'handwriting-config',
      builder: (context, state) =>
          HandwritingConfigPage(initial: state.extra as HandwritingConfig?),
    ),
  ],
);
