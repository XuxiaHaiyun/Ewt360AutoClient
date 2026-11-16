/// Web 平台 PDF 打开实现: 字节构造成 Blob 后经 object URL 在新标签页打开,
/// 延迟 1s 回收 object URL, 不访问文件系统。
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web 平台 PDF 打开实现
///
/// 通过 Blob URL 在新标签页打开 (浏览器自带 PDF 查看器), 不访问文件系统。
Future<void> openPdfImpl(String filename, List<int> bytes) async {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final blob = web.Blob(
    [data.toJS].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);
  web.window.open(url, '_blank');
  // 延迟回收 object URL, 避免新标签页尚未加载完成就被回收
  Future<void>.delayed(const Duration(seconds: 1), () {
    web.URL.revokeObjectURL(url);
  });
}