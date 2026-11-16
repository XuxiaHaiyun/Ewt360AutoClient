/// Windows 保活能力 (Win32 API, dart:ffi) — 平台分发门面
///
/// - io 平台 (Windows/Android/...): [windows_keep_alive_io.dart]
///   (Win32 实现仅在 Windows 生效, 其他 io 平台安全降级为 no-op)
/// - Web: [windows_keep_alive_web.dart] (无 Win32 API, 全部 no-op)
library;

export 'windows_keep_alive_io.dart'
    if (dart.library.js_interop) 'windows_keep_alive_web.dart';
