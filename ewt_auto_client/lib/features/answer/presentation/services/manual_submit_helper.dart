/// 手动提交流程编排器：逐课程打开手动填写页收集结果，再经 AnswerSubmitService 批量提交。
/// 供"下载方案"提交页与"提交试卷"共同调用，保证提交路径一致；任一课程中途取消即中止整个流程。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../player/domain/entities/video_session.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../data/datasources/answer_remote_datasource.dart';
import '../../data/services/oss_upload_service.dart';
import '../../domain/entities/image_upload_config.dart';
import '../../domain/entities/question_info.dart';
import '../../domain/services/answer_submit_service.dart';
import '../pages/manual_answer_submit_page.dart';

/// 手动提交流程编排器
///
/// 复用"提交试卷"功能模块的核心逻辑:
/// 1. 逐课程打开 [ManualAnswerSubmitPage] 手动填写 (可选选择题 / 传图片, 单题多张);
///    - 单试卷: 直接打开单试卷填写页
///    - 多试卷: 打开 TAB 切换填写页, 一次填写所有试卷
/// 2. 收集各课程填写结果 ([ManualSubmitInput]);
/// 3. 通过 [AnswerSubmitService] + [TaskProgressDialog] 批量提交。
///
/// 供"下载方案"提交页 ([AnswerPdfPreviewPage]) 与"提交试卷" ([SubmitPaperHelper])
/// 共同调用, 避免逻辑重复、保证提交路径一致。
class ManualSubmitOrchestrator {
  const ManualSubmitOrchestrator._();

  /// 逐课程手动填写并批量提交。
  ///
  /// [rootNavigator] 是否用 rootNavigator 打开独立全屏填写页
  ///   (覆盖壳层侧栏/底栏, 对齐"提交试卷" new_window 行为)。
  /// [pdfByPaperId] 可选: paperId → 答案 PDF 字节。传入后, 每个填写页在存在对应
  ///   答案 PDF 时, 右上角提供"查看答案 PDF"入口, 点击打开双栏 (左 PDF 预览 / 右作答)。
  /// [showScopeDialog] 是否显示提交范围选择弹窗 (仅提交试卷多课程时生效)。
  /// [showAnswerPreview] 是否提供"查看答案"双栏预览 (左侧渲染已获取答案/解析,
  ///   供试题答案页"手动提交"任意获取方案边看答案边填写)。
  ///
  /// 返回 (ok, fail, cancelled): cancelled=true 表示用户在某一门中途取消 (中止整个流程)。
  static Future<({int ok, int fail, bool cancelled})> run({
    required BuildContext context,
    required List<CourseAnswerResult> results,
    required SubmitType type,
    bool rootNavigator = false,
    Map<String, Uint8List>? pdfByPaperId,
    bool showScopeDialog = false,
    bool showAnswerPreview = false,
  }) async {
    if (results.isEmpty || !context.mounted) {
      return (ok: 0, fail: 0, cancelled: false);
    }

    final effectiveResults = <CourseAnswerResult>[];
    final configs = <ImageUploadConfig>[];

    if (results.length == 1) {
      // 单试卷模式: 逐课程手动填写 (原逻辑)
      final r = results.first;
      if (!context.mounted) {
        return (ok: 0, fail: 0, cancelled: true);
      }
      final navigator = rootNavigator
          ? Navigator.of(context, rootNavigator: true)
          : Navigator.of(context);
      final input = await navigator.push<ManualSubmitInput>(
        MaterialPageRoute(
          builder: (_) => ManualAnswerSubmitPage.single(
            result: r,
            type: type,
            pdfBytes: pdfByPaperId != null ? pdfByPaperId[r.paperId] : null,
            showScopeDialog: showScopeDialog,
            showAnswerPreview: showAnswerPreview,
          ),
        ),
      );
      if (input == null || !context.mounted) {
        return (ok: 0, fail: 0, cancelled: true);
      }
      effectiveResults.add(_copyResultWithManual(r, input));
      configs.add(input.imageUploadConfig);
    } else {
      // 多试卷模式: 打开 TAB 切换填写页, 一次填写所有试卷
      if (!context.mounted) {
        return (ok: 0, fail: 0, cancelled: true);
      }
      final navigator = rootNavigator
          ? Navigator.of(context, rootNavigator: true)
          : Navigator.of(context);
      final batchInput = await navigator.push<ManualSubmitBatchInput>(
        MaterialPageRoute(
          builder: (_) => ManualAnswerSubmitPage.multi(
            results: results,
            type: type,
            pdfByPaperId: pdfByPaperId,
            showScopeDialog: showScopeDialog,
            showAnswerPreview: showAnswerPreview,
          ),
        ),
      );
      if (batchInput == null || !context.mounted) {
        return (ok: 0, fail: 0, cancelled: true);
      }
      // 将批量填写结果转换为有效结果
      for (int i = 0; i < results.length && i < batchInput.inputs.length; i++) {
        effectiveResults.add(_copyResultWithManual(results[i], batchInput.inputs[i]));
        configs.add(batchInput.inputs[i].imageUploadConfig);
      }
    }

    if (effectiveResults.isEmpty || !context.mounted) {
      return (ok: 0, fail: 0, cancelled: false);
    }

    // 阶段2: 构建提交服务 + 进度弹窗
    final dioClient = getIt<DioClient>();
    final service = AnswerSubmitService(
      AnswerRemoteDataSource(dioClient),
      ossUploader: OssUploadService(dioClient),
      renderContext: context,
    );
    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '答题结果';
    final dialogKey = GlobalKey<TaskProgressDialogState>();
    final items = effectiveResults
        .map(
          (r) => TaskProgressItem(
            title: r.courseTitle,
            subtitle: 'paperId=${r.paperId}',
            state: PlaybackState.initializing,
            progress: 0.0,
          ),
        )
        .toList();
    var stopped = false;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: '手动提交$typeLabel',
      dialogKey: dialogKey,
      onStop: () {
        stopped = true;
        service.cancel();
      },
    );

    // 阶段3: 批量提交
    int ok = 0;
    int fail = 0;
    for (int i = 0; i < effectiveResults.length; i++) {
      if (stopped) break;
      final r = effectiveResults[i];
      if (r.reportId.isEmpty) {
        items[i].state = PlaybackState.failed;
        items[i].progress = 1.0;
        items[i].message = '缺少 reportId, 跳过';
        fail++;
        continue;
      }
      items[i].state = PlaybackState.playing;
      items[i].progress = 0.1;
      items[i].message = '提交$typeLabel中...';

      SubmitResult sr;
      try {
        sr = await service.submit(
          result: r,
          type: type,
          selectedQuestions: r.questions,
          imageUploadConfig: configs[i],
        );
      } catch (e) {
        sr = SubmitResult(
          success: false,
          message: '提交异常: $e',
          submittedCount: 0,
          type: type,
        );
      }
      items[i].state = sr.success ? PlaybackState.completed : PlaybackState.failed;
      items[i].progress = 1.0;
      items[i].message = sr.message;
      sr.success ? ok++ : fail++;
    }
    service.dispose();

    if (!stopped) dialogKey.currentState?.markFinished();
    return (ok: ok, fail: fail, cancelled: false);
  }

  /// 用手动填写结果覆盖课程题目与 reportId, 构造待提交结果
  static CourseAnswerResult _copyResultWithManual(
    CourseAnswerResult r,
    ManualSubmitInput input,
  ) {
    return CourseAnswerResult(
      courseTitle: r.courseTitle,
      method: r.method,
      paperId: r.paperId,
      questions: input.questions,
      successCount: r.successCount,
      totalCount: r.totalCount,
      dayId: r.dayId,
      dateLabel: r.dateLabel,
      subjectName: r.subjectName,
      reportId: input.reportId,
      bizCode: r.bizCode,
      homeworkId: r.homeworkId,
      platform: r.platform,
      assignPoints: r.assignPoints,
      paperPackageId: r.paperPackageId,
      userId: r.userId,
    );
  }
}
