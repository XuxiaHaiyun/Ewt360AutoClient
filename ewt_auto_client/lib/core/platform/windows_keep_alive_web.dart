/// Web 平台 stub: 无 Win32 API, 全部静默 no-op
///
/// API 与 [windows_keep_alive_io.dart] 的 Windows 实现保持一致,
/// 经 windows_keep_alive.dart 条件导出按平台分发。
class WindowsKeepAlive {
  WindowsKeepAlive._();

  /// Web 平台不支持, 恒返回 false
  static bool setHighPriority() => setPriority(high: true);

  /// Web 平台不支持, 恒返回 false
  static bool setPriority({required bool high}) => false;

  /// Web 平台不支持, 恒返回 false
  static bool setPreventSleep({bool prevent = true, bool keepDisplay = false}) {
    return false;
  }
}
