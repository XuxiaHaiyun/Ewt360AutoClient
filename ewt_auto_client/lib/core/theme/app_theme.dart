/// Material 3 主题: 基于 ColorScheme.fromSeed (tonalSpot) 构建亮/暗两套主题,
/// 支持设置页动态强调色、全局字体与页面过渡动画方案。
library;

import 'package:flutter/material.dart';

/// Material Design 3 主题
///
/// 使用 ColorScheme.fromSeed 实现标准 M3 动态配色 (tonalSpot 方案,
/// 主题色忠实跟随强调色色相, 是 Android Material You 的默认行为;
/// expressive 变体色相旋转过大, 会导致强调色选择与实际观感脱节)。
/// 亮/暗两套主题共享同一份组件样式配置 [_base]，仅 ColorScheme 不同，
/// 保证各组件 (弹窗/卡片/输入框/导航/按钮等) 风格全局一致。
///
/// 种子色可通过设置页"强调色"动态指定，未指定时使用 [defaultSeed]。
abstract final class AppTheme {
  /// 默认种子色 (EWT 品牌蓝)，同时也是设置页"强调色"的默认选项
  static const Color defaultSeed = Color(0xFF1565C0);

  /// 强调色在 SharedPreferences 中的持久化键 (设置页与风控启动弹窗共用)
  static const String accentColorPrefKey = 'settings_accentColor';

  /// 强调色预设 (名称 + 种子色)。设置页选择后以 `color.toARGB32()` 持久化。
  static const List<({String name, Color color})> accentPresets = [
    (name: '品牌蓝', color: defaultSeed),
    (name: '赛博青', color: Color(0xFF00B8D4)),
    (name: '极光紫', color: Color(0xFF7B61FF)),
    (name: '翡翠绿', color: Color(0xFF00B894)),
    (name: '熔岩橙', color: Color(0xFFE17055)),
    (name: '霓虹粉', color: Color(0xFFFD79A8)),
    (name: '琥珀金', color: Color(0xFFF9A825)),
    (name: '靛蓝夜', color: Color(0xFF3949AB)),
  ];

  /// 从持久化值解析种子色；无效或未保存时回退 [defaultSeed]
  static Color seedFromValue(int? value) {
    if (value == null) return defaultSeed;
    for (final preset in accentPresets) {
      if (preset.color.toARGB32() == value) return preset.color;
    }
    return defaultSeed;
  }

  static ThemeData light(
    Color? seed, {
    String? fontFamily,
    String pageTransition = 'native',
  }) =>
      _base(
        ColorScheme.fromSeed(
          seedColor: seed ?? defaultSeed,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
        ),
        fontFamily: fontFamily,
        pageTransition: pageTransition,
      );

  static ThemeData dark(
    Color? seed, {
    String? fontFamily,
    String pageTransition = 'native',
  }) =>
      _base(
        ColorScheme.fromSeed(
          seedColor: seed ?? defaultSeed,
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
        ),
        fontFamily: fontFamily,
        pageTransition: pageTransition,
      );

  /// 页面过渡动画方案 (设置页"显示 → 页面过渡动画", 默认 native 平台默认)
  static PageTransitionsTheme _pageTransitionsTheme(String kind) {
    const platforms = [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ];
    PageTransitionsBuilder builder;
    switch (kind) {
      case 'fade':
        builder = const _FadePageTransitionsBuilder();
      case 'slide':
        builder = const _SlidePageTransitionsBuilder();
      case 'none':
        builder = const _NoPageTransitionsBuilder();
      default:
        return const PageTransitionsTheme(); // native: Flutter 平台默认
    }
    return PageTransitionsTheme(builders: {for (final p in platforms) p: builder});
  }

  /// 公共组件样式基线：亮/暗主题共用，仅注入不同的 [scheme]
  static ThemeData _base(
    ColorScheme scheme, {
    String? fontFamily,
    String pageTransition = 'native',
  }) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      pageTransitionsTheme: _pageTransitionsTheme(pageTransition),
      scaffoldBackgroundColor: isDark ? scheme.surface : scheme.surfaceContainerLowest,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        labelType: NavigationRailLabelType.all,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        backgroundColor: scheme.inverseSurface,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineWidth: WidgetStatePropertyAll(0),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 15),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        space: 1,
        thickness: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      datePickerTheme: DatePickerThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
  }
}

/// 页面过渡: 渐显
class _FadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

/// 页面过渡: 右侧滑入
class _SlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const _SlidePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: animation.drive(
        Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
      ),
      child: child,
    );
  }
}

/// 页面过渡: 无动画
class _NoPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
