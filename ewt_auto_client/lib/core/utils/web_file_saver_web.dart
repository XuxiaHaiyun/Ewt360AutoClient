/// Web 平台文件保存实现: 字节构造 Blob 后经 a 标签 download 属性触发浏览器下载,
/// 返回 filename 作为标识 (与 native 返回路径对齐), 无文件系统访问。
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web 平台文件保存实现
///
/// 通过 Blob + URL.createObjectURL + a 标签触发浏览器下载,
/// 不访问文件系统 (Web 平台无 dart:io File)。
///
/// 返回 filename (与 native 版返回路径对齐, 调用方用作日志标识)。
Future<String> saveBytesImpl(String filename, List<int> bytes) async {
  // List<int> → Uint8List → JSUint8Array
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final jsData = data.toJS;

  // Blob 构造: new Blob([jsData], { type: 'application/octet-stream' })
  final blob = web.Blob(
    [jsData].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);

  // 创建 a 标签触发下载
  final anchor =
      web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = filename;
  // 不挂载到 DOM 也能触发点击下载, 但部分浏览器需要挂载
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();

  // 释放 object URL (异步, 避免下载未完成就回收)
  Future<void>.delayed(const Duration(seconds: 1), () {
    web.URL.revokeObjectURL(url);
  });

  return filename;
}
