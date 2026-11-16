/// Native 平台文件保存实现: 字节写入用户下载目录 `EwtAutoClient/` 下
/// 以 filename 命名的文件, 与 DownloadService 的保存目录约定一致, 返回实际保存路径。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Native 平台 (Android/Windows/iOS/macOS/Linux) 文件保存实现
///
/// 写入用户下载目录 (`EwtAutoClient/<subDir>/<filename>`),
/// 与 `DownloadService._getSaveDir` 一致。
Future<String> saveBytesImpl(String filename, List<int> bytes) async {
  final dir = await getDownloadsDirectory() ??
      await getApplicationDocumentsDirectory();
  final saveDir = Directory('${dir.path}/EwtAutoClient');
  if (!saveDir.existsSync()) {
    saveDir.createSync(recursive: true);
  }
  final filepath = '${saveDir.path}/$filename';
  final file = File(filepath);
  await file.writeAsBytes(bytes);
  return filepath;
}
