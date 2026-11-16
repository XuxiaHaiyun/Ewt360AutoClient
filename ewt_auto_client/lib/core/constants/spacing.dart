/// 统一间距/圆角常量 (基于 4px 栅格)。
library;

import 'package:flutter/material.dart';

/// 统一间距/圆角常量 (基于 4px 栅格)。
///
/// 页面内禁止手写 4/8/12/16/24 等 spacing 魔数, 统一引用本类,
/// 便于全局调整视觉密度。
abstract final class Spacing {
  // 间距
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  // 常用 EdgeInsets 快捷方式
  static const EdgeInsets pagePadding = EdgeInsets.all(lg);
  static const EdgeInsets cardPadding = EdgeInsets.all(lg);

  // 圆角
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 20;
}
