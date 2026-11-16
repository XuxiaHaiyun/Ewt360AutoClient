/// 应用级轻量反馈工具，showAppSnackBar 展示悬浮 SnackBar（自动清除上一条避免堆积，错误红色强调）。
library;

import 'package:flutter/material.dart';

/// 轻量提示 (SnackBar)
///
/// 用于刷新完成 / 操作结果等轻量反馈。自动清除上一条提示, 避免排队堆积。
/// [isError] 为 true 时使用红色背景强调失败。
void showAppSnackBar(
  ScaffoldMessengerState messenger,
  String message, {
  bool isError = false,
}) {
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
}
