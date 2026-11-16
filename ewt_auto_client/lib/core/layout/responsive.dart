/// 响应式布局组件: 按窗口档位回退选择的 ResponsiveBuilder、
/// 居中限幅 ResponsiveCenter 与自动列数的 AdaptiveGrid。
library;

import 'package:flutter/material.dart';

import 'app_breakpoints.dart';

/// 响应式构建器: 根据当前 [WindowSize] 档位选择不同布局。
///
/// [compact] 为空时回退到 [medium], 其余档位逐级向上回退,
/// 因此最简用法只需提供 compact + wide 两套布局。
class ResponsiveBuilder extends StatelessWidget {
  final Widget? Function(BuildContext, WindowSize size) compact;
  final Widget? Function(BuildContext, WindowSize size)? medium;
  final Widget? Function(BuildContext, WindowSize size)? expanded;
  final Widget? Function(BuildContext, WindowSize size)? large;

  const ResponsiveBuilder({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
    this.large,
  });

  @override
  Widget build(BuildContext context) {
    final size = context.windowSize;
    // 从当前档位向下找到第一个非空构建器, 保证只传两套布局也能覆盖全档位。
    final builders = [compact, medium, expanded, large];
    for (var i = size.index; i >= 0; i--) {
      final widget = builders[i]?.call(context, size);
      if (widget != null) return widget;
    }
    return const SizedBox.shrink();
  }
}

/// 居中限幅容器: 把内容限制在 [maxWidth] 内并水平居中。
///
/// 用于宽屏上防止表单/列表被拉伸到不可读, 替代各页面散落的
/// `ConstrainedBox(maxWidth: 460/520/640/700)` 写法。
class ResponsiveCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = AppBreakpoints.contentMaxWidth,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 自适应网格: 在给定宽度内按 [maxCrossAxisExtent] 计算列数,
/// 宽屏自动加列, 不需要页面手写 crossAxisCount 分支。
class AdaptiveGrid extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double maxCrossAxisExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final double childAspectRatio;
  final EdgeInsetsGeometry padding;
  final ScrollController? controller;

  const AdaptiveGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.maxCrossAxisExtent = 480,
    this.mainAxisSpacing = 12,
    this.crossAxisSpacing = 12,
    this.childAspectRatio = 1.0,
    this.padding = EdgeInsets.zero,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width.isFinite && width > 0
            ? (width ~/ maxCrossAxisExtent).clamp(1, 6)
            : 1;
        return GridView.builder(
          controller: controller,
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: mainAxisSpacing,
            crossAxisSpacing: crossAxisSpacing,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
