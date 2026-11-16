/// Windows 保活能力 (dart:ffi 调 kernel32): 提高进程优先级与阻止系统休眠;
/// 非 Windows 平台或 FFI 失败时安全降级为 no-op。
library;

import 'dart:ffi';
import 'dart:io';

/// Windows 保活能力 (Win32 API, dart:ffi)
///
/// - [setHighPriority]: SetPriorityClass(HIGH_PRIORITY_CLASS)，降低被系统
///   降级/抢占的概率，避免后台任务被节流;
/// - [setPreventSleep]: SetThreadExecutionState(ES_CONTINUOUS |
///   ES_SYSTEM_REQUIRED)，应用运行期间阻止系统自动休眠。
///
/// 仅 Windows 生效；其他平台所有方法为静默 no-op。
/// FFI 声明失败 (如非 Windows、缺 kernel32) 时全部安全降级。
class WindowsKeepAlive {
  WindowsKeepAlive._();

  static const int _esContinuous = 0x80000000;
  static const int _esSystemRequired = 0x00000001;
  static const int _esDisplayRequired = 0x00000002;

  static DynamicLibrary? _kernel32;

  static DynamicLibrary? get _lib {
    if (!Platform.isWindows) return null;
    try {
      return _kernel32 ??= DynamicLibrary.open('kernel32.dll');
    } catch (_) {
      return null;
    }
  }

  /// 提高进程优先级 (HIGH_PRIORITY_CLASS)
  static bool setHighPriority() => setPriority(high: true);

  /// 设置进程优先级。
  ///
  /// [high] 为 true 用 HIGH_PRIORITY_CLASS, false 恢复 NORMAL_PRIORITY_CLASS。
  static bool setPriority({required bool high}) {
    final lib = _lib;
    if (lib == null) return false;
    const highPriorityClass = 0x00000080;
    const normalPriorityClass = 0x00000020;
    try {
      // HANDLE 实际是指针大小的整型, 用 Pointer<Void> 表达最稳妥
      final getCurrentProcess =
          lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
              'GetCurrentProcess');
      final setPriorityClass = lib.lookupFunction<
          Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)>('SetPriorityClass');
      return setPriorityClass(
              getCurrentProcess(), high ? highPriorityClass : normalPriorityClass) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// 阻止系统自动休眠。
  ///
  /// [keepDisplay] 为 true 时同时阻止熄屏 (一般不需要, 屏幕常亮由
  /// Android 端 FLAG_KEEP_SCREEN_ON 负责, Windows 端按需开启)。
  static bool setPreventSleep({bool prevent = true, bool keepDisplay = false}) {
    final lib = _lib;
    if (lib == null) return false;
    try {
      final setThreadExecutionState = lib.lookupFunction<Uint32 Function(Uint32),
          int Function(int)>('SetThreadExecutionState');
      var flags = _esContinuous;
      if (prevent) flags |= _esSystemRequired;
      if (prevent && keepDisplay) flags |= _esDisplayRequired;
      // 传 ES_CONTINUOUS 表示持续生效; 传 0 (或仅 CONTINUOUS) 恢复系统默认
      return setThreadExecutionState(flags) != 0;
    } catch (_) {
      return false;
    }
  }
}
