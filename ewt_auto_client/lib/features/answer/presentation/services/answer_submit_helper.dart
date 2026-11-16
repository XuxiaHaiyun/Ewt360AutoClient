/// 获取完成后自动提交助手，按预配置的题型筛选与图片上传方案批量提交做题痕迹/作答结果。
/// dialogContext 非空时弹进度弹窗；为 null 时静默执行，日志经 onLog 回调接入账号级进度日志。
library;

import 'package:flutter/widgets.dart';

import '../../../../core/network/dio_client.dart';
import '../../../player/domain/entities/video_session.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../data/datasources/answer_remote_datasource.dart';
import '../../data/services/oss_upload_service.dart';
import '../../domain/entities/image_upload_config.dart';
import '../../domain/entities/question_info.dart';
import '../../domain/services/answer_submit_service.dart';

/// 获取完成后自动提交助手
///
/// 供"获取完成操作"使用: 获取答案完成后, 按预配置的提交配置
/// (题型筛选 + 图片上传方案) 批量提交做题痕迹 / 作答结果。
///
/// 两种用法:
/// - 单任务流程 ([dialogContext] 非空): 弹出 [TaskProgressDialog] 实时展示
///   进度与日志, 完成后自动标记完成;
/// - 批量任务流程 ([dialogContext] 为 null): 静默执行, 日志通过 [onLog]
///   回调接入账号级进度日志 (批量任务每账号独立 DioClient)。
class AnswerSubmitHelper {
  AnswerSubmitHelper._();

  /// 批量提交获取到的答案
  ///
  /// [client] 账号对应的 DioClient (批量任务每账号独立实例)
  /// [type] trace=提交做题痕迹, result=提交作答结果
  /// [questionTypes] 题型筛选 (空集合 = 全部题型)
  /// [imageUploadConfig] 图片上传类题型的方案配置 (null = 不上传图片)
  /// [dialogContext] 非空时显示进度弹窗; null 时静默执行
  /// [onLog] 日志回调 (批量任务接入账号日志)
  static Future<({int success, int fail})> submitResults({
    required DioClient client,
    required List<CourseAnswerResult> results,
    required SubmitType type,
    Set<String> questionTypes = const {},
    ImageUploadConfig? imageUploadConfig,
    BuildContext? dialogContext,
    void Function(String message, LogLevel level)? onLog,
  }) async {
    if (results.isEmpty) return (success: 0, fail: 0);
    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '作答结果';

    final service = AnswerSubmitService(
      AnswerRemoteDataSource(client),
      ossUploader: OssUploadService(client),
      renderContext: dialogContext,
    );
    final logSub =
        service.logStream.listen((e) => onLog?.call(e.message, e.level));

    final dialogKey =
        dialogContext != null ? GlobalKey<TaskProgressDialogState>() : null;
    final items = results
        .map((r) => TaskProgressItem(
              title: r.courseTitle,
              subtitle: 'paperId=${r.paperId}',
              state: PlaybackState.initializing,
              progress: 0.0,
            ))
        .toList();
    var stopped = false;
    if (dialogContext != null && dialogKey != null) {
      TaskProgressDialog.show(
        dialogContext,
        items: items,
        logStream: service.logStream,
        title: '提交$typeLabel',
        dialogKey: dialogKey,
        onStop: () {
          stopped = true;
          service.cancel();
        },
      );
    }

    onLog?.call('开始提交$typeLabel (${results.length} 个课程)...',
        LogLevel.info);

    int success = 0;
    int fail = 0;
    for (int i = 0; i < results.length; i++) {
      if (stopped) break;
      final r = results[i];

      if (r.reportId.isEmpty) {
        fail++;
        if (dialogContext != null && i < items.length) {
          items[i].state = PlaybackState.failed;
          items[i].progress = 1.0;
          items[i].message = '缺少 reportId, 跳过';
        }
        onLog?.call('  ✗ ${r.courseTitle}: 缺少 reportId, 跳过',
            LogLevel.warning);
        continue;
      }

      // 题型过滤 (空集合 = 全部题型)
      var questions = r.questions;
      if (questionTypes.isNotEmpty) {
        questions = questions
            .where((q) => questionTypes.contains(q.questionType))
            .toList();
      }
      if (questions.isEmpty) {
        fail++;
        if (dialogContext != null && i < items.length) {
          items[i].state = PlaybackState.failed;
          items[i].progress = 1.0;
          items[i].message = '无匹配题型的题目, 跳过';
        }
        onLog?.call('  ✗ ${r.courseTitle}: 无匹配题型的题目, 跳过',
            LogLevel.warning);
        continue;
      }

      if (dialogContext != null && i < items.length) {
        items[i].state = PlaybackState.playing;
        items[i].progress = 0.1;
        items[i].message = '提交$typeLabel中...';
      }

      SubmitResult sr;
      try {
        sr = await service.submit(
          result: r,
          type: type,
          selectedQuestions: questions,
          imageUploadConfig: imageUploadConfig,
        );
      } catch (e) {
        sr = SubmitResult(
          success: false,
          message: '提交异常: $e',
          submittedCount: 0,
          type: type,
        );
      }

      if (dialogContext != null && i < items.length) {
        items[i].state =
            sr.success ? PlaybackState.completed : PlaybackState.failed;
        items[i].progress = 1.0;
        items[i].message = sr.message;
      }
      onLog?.call('  ${sr.success ? '✓' : '✗'} ${r.courseTitle}: ${sr.message}',
          sr.success ? LogLevel.info : LogLevel.error);
      if (sr.success) {
        success++;
      } else {
        fail++;
      }
    }

    await logSub.cancel();
    service.dispose();
    if (dialogKey != null) dialogKey.currentState?.markFinished();
    onLog?.call('提交完成: 成功 $success, 失败 $fail', LogLevel.info);
    return (success: success, fail: fail);
  }
}
