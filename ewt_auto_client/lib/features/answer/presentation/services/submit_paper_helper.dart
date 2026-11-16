/// "提交试卷"菜单入口辅助：仅取题不下载 PDF，走手动填写后批量提交答题结果。
/// 默认用 paperQuestionGroup 独立取题（可经风控开关切回逐题路径），课程间隔 1s、日志不出现"获取答案/方案"。
library;

import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../data/datasources/answer_remote_datasource.dart';
import '../../domain/services/answer_submit_service.dart';
import '../../presentation/services/answer_service.dart';
import 'manual_submit_helper.dart';

/// 手动提交试卷辅助 — "提交试卷" 菜单入口
///
/// 只获取题目、不下载试卷 PDF, 聚焦提交:
/// 1. 通过 [AnswerService.executeBatch] (method=questions) 独立取题:
///    用页面真实 reportId/bizCode 调 paperQuestionGroup 一次拉取整卷题目
///    (题干/选项/子题), 不走逐题 getQuestionAnalysis 的答案获取路径;
/// 2. 逐课程打开 [ManualAnswerSubmitPage] 手动填写 (可选选择题、可传图片);
/// 3. 通过 [AnswerSubmitService] + [TaskProgressDialog] 批量提交并记录日志。
class SubmitPaperHelper {
  const SubmitPaperHelper._();

  /// 执行"提交试卷": 获取 → 手动填写 → 提交 (答题结果)
  static Future<void> run(
    BuildContext context,
    List<Map<String, dynamic>> courses, {
    required String homeworkId,
    required String schoolId,
    SubmitType type = SubmitType.result,
  }) async {
    if (courses.isEmpty || !context.mounted) return;

    // ── 阶段1: 获取答案题目 (不下载 PDF) ──
    final answerService = AnswerService(client: getIt<DioClient>());
    final answerRemote = AnswerRemoteDataSource(getIt<DioClient>());
    final fetchKey = GlobalKey<TaskProgressDialogState>();
    final fetchItems = courses
        .map(
          (c) => TaskProgressItem(
            title:
                (c['taskTitle'] ??
                        c['title'] ??
                        c['taskName'] ??
                        c['name'] ??
                        '课程')
                    .toString(),
            subtitle: (c['lessonId'] ?? c['contentId'] ?? '').toString(),
          ),
        )
        .toList();
    var stopped = false;
    TaskProgressDialog.show(
      context,
      items: fetchItems,
      logStream: answerService.logStream,
      title: '获取试卷信息',
      dialogKey: fetchKey,
      onStop: () {
        stopped = true;
        answerService.cancel();
        answerService.dispose();
      },
    );

    // 细分开关: 默认独立取题 (paperQuestionGroup 一次拉全), 可远程切回逐题路径
    final useFetchQuestions =
        RiskControlGate.isFeatureEnabled('submit_paper.fetch_questions');
    var results = await answerService.executeBatch(
      courses,
      homeworkId: homeworkId,
      schoolId: schoolId,
      method: useFetchQuestions ? 'questions' : 'escalation',
      // 提交试卷优化: 独立取题路径 (paperQuestionGroup 一次拉全), 课程间隔 1s,
      // 日志不含"获取答案/方案"
      courseInterval: const Duration(seconds: 1),
      analysisWorkers: 1,
      neutralLog: true,
      onItemUpdate: (index, item) {
        if (index < fetchItems.length) {
          fetchItems[index].state = item.state;
          fetchItems[index].progress = item.progress;
          fetchItems[index].message = item.message;
          fetchItems[index].error = item.error;
        }
      },
    );

    // 补齐 reportId (对齐下载方案: 周培优等课程 direct 结果缺少 reportId,
    // 提交时会因缺少 reportId 跳过, 故按 204 兜底获取)
    if (!stopped) {
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        if (r.reportId.isNotEmpty) continue;
        try {
          final reportResult = await answerRemote.getAnswerReport(
            paperId: r.paperId,
            bizCode: '204',
          );
          if (reportResult['success'] == true) {
            final data = reportResult['data'];
            if (data is Map<String, dynamic>) {
              final rid = (data['reportId'] ?? '').toString();
              if (rid.isNotEmpty && rid != '0') {
                results[i] = r.copyWith(reportId: rid);
              }
            }
          }
        } catch (_) {
          // 兜底失败不影响主流程, 交由提交阶段按"缺少 reportId"处理
        }
      }
    }
    answerService.dispose();

    if (stopped || !context.mounted) return;
    fetchKey.currentState?.markFinished();

    if (results.isEmpty) {
      _toast(context, '没有获取到可提交的试卷', success: false);
      return;
    }

    // ── 阶段2+3: 复用"提交试卷"手动填写 + 批量提交 (ManualSubmitOrchestrator) ──
    final useNewWindow =
        RiskControlGate.isFeatureEnabled('submit_paper.new_window');
    final orchestratorResult = await ManualSubmitOrchestrator.run(
      context: context,
      results: results,
      type: type,
      rootNavigator: useNewWindow,
      showScopeDialog: courses.length > 1,
    );
    if (orchestratorResult.cancelled) return;
    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '答题结果';
    if (orchestratorResult.fail == 0) {
      _toast(
        context,
        '全部 ${orchestratorResult.ok} 个课程提交$typeLabel成功',
      );
    } else {
      _toast(
        context,
        '完成: 成功 ${orchestratorResult.ok}, 失败 ${orchestratorResult.fail}',
        success: false,
      );
    }
  }

  static void _toast(BuildContext context, String msg, {bool success = true}) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: success ? 3 : 5),
          backgroundColor: success
              ? Colors.green.shade700
              : Colors.red.shade700,
        ),
      );
  }
}
