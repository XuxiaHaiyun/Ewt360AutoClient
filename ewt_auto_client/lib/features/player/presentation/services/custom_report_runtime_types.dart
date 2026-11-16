/// 自定义上报脚本运行时的平台中立共享类型
///
/// 供 native (quickjs_engine) / web (stub) 两套运行时实现共用;
/// 不能引入 quickjs_engine (dart:ffi), 否则 Web 编译失败。
library;

/// 脚本运行时异常
class ScriptRuntimeException implements Exception {
  final String message;
  const ScriptRuntimeException(this.message);

  @override
  String toString() => message;
}
