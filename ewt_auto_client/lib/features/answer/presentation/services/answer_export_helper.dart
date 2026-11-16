/// 获取完成后自动导出助手，按导出模式（每课程单独/全部合并）批量导出答案 PDF 到下载目录。
/// 保存目录为 `下载/EwtAutoClient/试题答案`，无下载目录时回退到应用文档目录。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/entities/question_info.dart';
import '../../domain/services/paper_pdf_exporter.dart';
import '../../domain/entities/answer_config.dart';

/// 获取完成后自动导出助手
///
/// 供"获取完成操作"使用: 获取答案完成后按导出模式批量导出 PDF。
/// - [AnswerExportMode.all]: 全部课程合并为单个 PDF
/// - [AnswerExportMode.each]: 每个课程导出一个 PDF
///
/// 保存目录: `下载/EwtAutoClient/试题答案` (无下载目录时回退到应用文档目录)。
class AnswerExportHelper {
  AnswerExportHelper._();

  /// 批量导出答案
  ///
  /// [results] 课程答案结果
  /// [mode] 导出模式 (all=合并单文件 / each=每课程单独)
  /// [prefix] 文件名前缀 (如账号名, 用于区分多个账号的导出)
  /// [subDir] 保存子目录 (默认 试题答案)
  ///
  /// 返回: (success, fail), all 模式 success 0/1。
  static Future<({int success, int fail})> exportResults({
    required List<CourseAnswerResult> results,
    required AnswerExportMode mode,
    String prefix = '',
    String subDir = '试题答案',
  }) async {
    if (results.isEmpty) return (success: 0, fail: 0);

    final dir = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final saveDir = Directory(
      [dir.path, 'EwtAutoClient', subDir].join(Platform.pathSeparator),
    );
    if (!saveDir.existsSync()) {
      saveDir.createSync(recursive: true);
    }

    if (mode == AnswerExportMode.all) {
      final filepath =
          '${saveDir.path}/${_sanitize('$prefix批量答案')}.pdf';
      final ok = await PaperPdfExporter.exportBatch(
        results,
        filepath,
        includeAnswer: true,
        docTitle: '$prefix批量答案',
        showSuccess: true,
      );
      return (success: ok ? 1 : 0, fail: ok ? 0 : 1);
    }

    // 每课程单独导出
    int success = 0;
    for (final r in results) {
      final filepath =
          '${saveDir.path}/${_sanitize('$prefix${r.courseTitle}')}.pdf';
      final ok = await PaperPdfExporter.export(
        r,
        filepath,
        includeAnswer: true,
        docTitle: r.courseTitle,
        showSuccess: true,
      );
      if (ok) success++;
    }
    return (success: success, fail: results.length - success);
  }

  /// 文件名净化 (去掉非法字符)
  static String _sanitize(String name) {
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
