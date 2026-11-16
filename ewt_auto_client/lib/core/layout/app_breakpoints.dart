/// 全局响应式断点体系: 窗口宽度档位 (compact/medium/expanded/large)、
/// 内容限幅常量及 BuildContext 扩展, 页面宽度分支统一引用本文件。
library;

import 'package:flutter/material.dart';

/// 全局统一响应式断点体系。
///
/// 各档位参考 Material Design 窗口类:
/// - compact  (<600)   手机竖屏: 单列、NavigationBar
/// - medium   (600~839) 小平板/横屏手机: 双列网格
/// - expanded (840~1199) 平板/小窗口桌面: 双列+侧栏
/// - large    (>=1200) 桌面/大屏: 三列、宽限幅
///
/// 所有页面级宽度分支必须使用本常量, 禁止再散落 600/720/840 魔数。
abstract final class AppBreakpoints {
  static const double compact = 600;
  static const double expanded = 840;
  static const double large = 1200;

  /// 表单类内容的最大限幅 (登录表单、居中卡片等)
  static const double formMaxWidth = 520;
  static const double contentMaxWidth = 720;

  /// 登录页表单列宽
  static const double loginFormMaxWidth = 460;
  /// 登录页窄面板 (协议/验证码等子面板)
  static const double loginPanelMaxWidth = 520;
  /// 中型对话框内容宽度
  static const double dialogMaxWidth = 640;
}

/// 当前窗口/画布的宽度档位。
enum WindowSize {
  compact,
  medium,
  expanded,
  large;

  /// 从任意宽度解析档位。
  static WindowSize fromWidth(double width) {
    if (width >= AppBreakpoints.large) return WindowSize.large;
    if (width >= AppBreakpoints.expanded) return WindowSize.expanded;
    if (width >= AppBreakpoints.compact) return WindowSize.medium;
    return WindowSize.compact;
  }

  /// 是否允许并排双栏 (medium 及以上)。
  bool get isTwoPane => index >= WindowSize.medium.index;
}

extension AppBreakpointsX on BuildContext {
  /// 窗口内容宽度 (响应 MediaQuery 变化, 优于 MediaQuery.of)。
  double get screenWidth => MediaQuery.sizeOf(this).width;

  WindowSize get windowSize => WindowSize.fromWidth(screenWidth);

  /// 宽屏 (expanded+): 可用网格双列以上/分栏布局。
  bool get isWide => screenWidth >= AppBreakpoints.expanded;

  /// 窄屏 (compact): 单列、底部导航。
  bool get isNarrow => screenWidth < AppBreakpoints.compact;
}
