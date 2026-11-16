/// 跨平台 PDF 打开工具入口: Native 写临时文件后用系统查看器打开,
/// Web 通过 Blob URL 在新标签页打开 (条件导入切换实现)。
library;

import 'pdf_viewer_native.dart'
    if (dart.library.js_interop) 'pdf_viewer_web.dart'
    as impl;

/// 跨平台 PDF 打开工具
///
/// - Native: 写入临时文件 + url_launcher 打开 file:// (用系统 PDF 查看器)
/// - Web: 生成 Blob URL 在新标签页打开 (浏览器自带 PDF 查看器)
class PdfViewer {
  PdfViewer._();

  /// 打开/查看 PDF
  ///
  /// [filename] 含扩展名 (如 "lesson1.pdf")
  /// [bytes] PDF 文件字节
  static Future<void> open(
    String filename,
    List<int> bytes,
  ) {
    return impl.openPdfImpl(filename, bytes);
  }
}