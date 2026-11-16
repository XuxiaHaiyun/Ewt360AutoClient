/// 响应式自适应布局壳：窄屏底部导航、中屏 icon Rail、宽屏带标签 Rail，导航 TAB 可在设置中自定义。
/// '设置' TAB 固定显示不可隐藏且始终排在最后。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:ewt_auto_client/core/layout/app_breakpoints.dart';
import 'package:ewt_auto_client/features/settings/presentation/providers/settings_provider.dart';

/// 响应式自适应布局壳
///
/// - Compact (<600dp): NavigationBar 底部导航
/// - Medium (600-840dp): NavigationRail (icon only)
/// - Expanded (>=840dp): NavigationRail (带标签) + 宽内容区
///
/// 导航 TAB 可通过设置页"显示 → 主页导航 TAB"自定义显示,
/// '设置' TAB 固定显示不可隐藏。
class AdaptiveScaffold extends ConsumerWidget {
  final Widget child;

  const AdaptiveScaffold({super.key, required this.child});

  /// 可选 TAB (路由 → 图标/标签), '设置' 不在此列表 (固定显示)
  static const _optionalTabs = [
    (route: '/home', icon: Icons.home_outlined, selectedIcon: Icons.home, label: '首页'),
    (route: '/tasks', icon: Icons.assignment_outlined, selectedIcon: Icons.assignment, label: '任务'),
    (route: '/weekend', icon: Icons.school_outlined, selectedIcon: Icons.school, label: '周培优'),
  ];

  /// 固定 TAB: 设置
  static const _settingsTab = (
    route: '/settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: '设置',
  );

  /// 过滤后的 TAB 列表 ('设置' 始终在最后)
  List<Map<String, Object>> _visibleTabs(List<String> enabledRoutes) {
    final tabs = <Map<String, Object>>[
      for (final t in _optionalTabs)
        if (enabledRoutes.contains(t.route))
          {
            'route': t.route,
            'icon': t.icon,
            'selectedIcon': t.selectedIcon,
            'label': t.label,
          },
    ];
    tabs.add({
      'route': _settingsTab.route,
      'icon': _settingsTab.icon,
      'selectedIcon': _settingsTab.selectedIcon,
      'label': _settingsTab.label,
    });
    return tabs;
  }

  int _currentIndex(BuildContext context, List<Map<String, Object>> tabs) {
    final location = GoRouterState.of(context).uri.path;
    for (var i = 0; i < tabs.length; i++) {
      final route = tabs[i]['route'] as String;
      if (location.startsWith(route)) return i;
    }
    return 0;
  }

  void _onDestinationSelected(BuildContext context, List<Map<String, Object>> tabs, int index) {
    context.go(tabs[index]['route'] as String);
  }

  /// 侧栏顶部品牌标: 圆角色块 + 主题色图标, 替代裸图标
  Widget _railLeading(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 20),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          Icons.auto_awesome,
          color: scheme.onPrimaryContainer,
          size: 24,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final visibleTabs = _visibleTabs(settings.visibleTabs);
    // 在 build 阶段读取当前路由路径, 不要在 LayoutBuilder.builder 内读取:
    // LayoutBuilder 的 builder 在 performLayout 的 layoutCallback 中执行,
    // 若其中读取 GoRouterState (注册 InheritedWidget 依赖), 路由切换时
    // (如侧栏切换 TAB / 教材库返回) 会在布局阶段重建 Navigator 子树并挂载
    // overlay entry, 触发 "mutated when none of its ancestors is actively
    // performing layout" 断言。在 build 阶段读取则元素重建发生在 build 阶段。
    final currentIndex = _currentIndex(context, visibleTabs);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isWide = width >= AppBreakpoints.compact;

        if (isWide) {
          // Medium / Expanded: NavigationRail; Large: 扩展侧栏 (图标+文字并排)
          final extended = width >= AppBreakpoints.large;
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: currentIndex,
                  onDestinationSelected: (i) =>
                      _onDestinationSelected(context, visibleTabs, i),
                  extended: extended,
                  // extended 与 labelType 互斥 (Flutter 断言), 扩展态始终带标签
                  labelType: extended
                      ? null
                      : width >= AppBreakpoints.expanded
                      ? NavigationRailLabelType.all
                      : NavigationRailLabelType.none,
                  leading: _railLeading(context),
                  groupAlignment: -1.0,
                  destinations: [
                    for (final t in visibleTabs)
                      NavigationRailDestination(
                        icon: Icon(t['icon'] as IconData),
                        selectedIcon: Icon(t['selectedIcon'] as IconData),
                        label: Text(t['label'] as String),
                      ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(child: child),
              ],
            ),
          );
        }

        // Compact: NavigationBar (设置可切悬浮胶囊样式)
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          body: child,
          bottomNavigationBar: settings.floatingBottomBar
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Material(
                    color: scheme.surfaceContainer,
                    elevation: 6,
                    shadowColor: scheme.shadow.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(28),
                    clipBehavior: Clip.antiAlias,
                    child: NavigationBar(
                      height: 64,
                      backgroundColor: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      selectedIndex: currentIndex,
                      onDestinationSelected: (i) => _onDestinationSelected(
                        context,
                        visibleTabs,
                        i,
                      ),
                      destinations: [
                        for (final t in visibleTabs)
                          NavigationDestination(
                            icon: Icon(t['icon'] as IconData),
                            selectedIcon: Icon(t['selectedIcon'] as IconData),
                            label: t['label'] as String,
                          ),
                      ],
                    ),
                  ),
                )
              : NavigationBar(
                  selectedIndex: currentIndex,
                  onDestinationSelected: (i) =>
                      _onDestinationSelected(context, visibleTabs, i),
                  destinations: [
                    for (final t in visibleTabs)
                      NavigationDestination(
                        icon: Icon(t['icon'] as IconData),
                        selectedIcon: Icon(t['selectedIcon'] as IconData),
                        label: t['label'] as String,
                      ),
                  ],
                ),
        );
      },
    );
  }
}
