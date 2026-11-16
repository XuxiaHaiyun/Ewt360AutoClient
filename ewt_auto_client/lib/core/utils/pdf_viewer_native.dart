/// Native 平台 PDF 打开实现: PDF 字节写入临时目录 (文件名非法字符替换为 _),
/// 经 url_launcher 以外部应用打开 file:// 地址。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Native 平台 (Android/Windows/iOS/macOS/Linux) PDF 打开实现
///
/// 将 PDF 字节写入临时目录, 再用系统 PDF 查看器打开 file:// 地址。
Future<void> openPdfImpl(String filename, List<int> bytes) async {
  final dir = await getTemporaryDirectory();
  final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final file = File('${dir.path}/$safeName');
  await file.writeAsBytes(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  await launchUrl(
    Uri.file(file.path),
    mode: LaunchMode.externalApplication,
  );
}