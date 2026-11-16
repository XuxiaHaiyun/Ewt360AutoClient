/// 跨平台文件保存工具入口: Native 写入用户下载目录 EwtAutoClient/,
/// Web 通过 Blob + a 标签触发浏览器下载 (条件导入切换实现)。
library;

import 'web_file_saver_native.dart'
    if (dart.library.js_interop) 'web_file_saver_web.dart'
    as impl;

/// 跨平台文件保存工具
///
/// - Native: 写入用户下载目录 (与 DownloadService._getSaveDir 一致)
/// - Web: 通过 Blob + a 标签触发浏览器下载 (无文件系统访问)
class WebFileSaver {
  WebFileSaver._();

  /// 保存字节数据为文件
  ///
  /// [filename] 含扩展名 (如 "lesson1.mp4")
  /// [bytes] 文件内容字节
  ///
  /// 返回保存路径 (native) 或下载标识 (web, 通常为 filename); 失败抛异常。
  static Future<String> saveBytes(
    String filename,
    List<int> bytes,
  ) async {
    return impl.saveBytesImpl(filename, bytes);
  }

  /// 保存文本为文件
  ///
  /// 便捷方法, 等价于 [saveBytes] + utf8.encode。
  static Future<String> saveText(
    String filename,
    String text,
  ) async {
    return impl.saveBytesImpl(filename, text.codeUnits);
  }
}
