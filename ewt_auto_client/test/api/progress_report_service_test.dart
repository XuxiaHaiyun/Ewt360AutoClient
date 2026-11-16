// ProgressReportService 端到端测试 (真实网关, 需 test/accounts.json)
//
// 复用 [ProgressReportService] 验证进度上报链路:
//   - executeBatch (1 个课程的完整模拟播放链路 - 真实上报, 快刷模式)
//
// 注意:
//   - 默认仅取 1 个课程做端到端测试, 避免大量上报
//   - 测试使用快刷模式 (fastBrush=true, fastBrushThreads=10) 避免耗时过长
//   - filterCourses 纯函数测试已移至 test/unit/logic/filters_test.dart
import 'package:ewt_auto_client/features/player/domain/entities/report_config.dart';
import 'package:ewt_auto_client/features/player/presentation/services/progress_report_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  ProgressReportService? reportService;

  // 共享状态
  String homeworkId = '';
  List<Map<String, dynamic>> courses = [];

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    if (h == null) return;
    reportService = ProgressReportService(
      client: h.client,
      endpointConfig: h.endpointConfig,
      userSession: h.session,
    );

    final prefetched = await prefetchHomeworkAndCourses(
      h.client,
      h.session.schoolId,
      maxCourses: 10,
    );
    homeworkId = prefetched.homeworkId;
    courses = prefetched.courses;
    // ignore: avoid_print
    print('setUpAll: homeworkId=$homeworkId, 课程数=${courses.length}');
  });
  tearDownAll(() {
    reportService?.dispose();
    harness?.dispose();
  });

  group('ProgressReportService.executeBatch - 端到端快刷上报', () {
    test('单课程快刷上报 (fastBrush=true, 1 轮)', () async {
      if (homeworkId.isEmpty || courses.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId 或课程');
        return;
      }

      // 找首个有 lessonId 的课程
      Map<String, dynamic>? target;
      for (final c in courses) {
        final lid = (c['lessonId'] ?? c['contentId'] ?? '').toString();
        if (lid.isNotEmpty) {
          target = c;
          break;
        }
      }
      if (target == null) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 课程列表中无有效 lessonId');
        return;
      }

      // 配置: 快刷模式, 仅 1 轮
      const cfg = ReportConfig(
        filterCompleted: false,
        selectedTypes: [null], // 全部类型
        selectedSubjects: [],
        fastBrush: true,
        fastBrushMaxRounds: 1,
      );

      final tasks = reportService!.filterCourses(
        [target],
        cfg,
        homeworkId,
        schoolId: harness!.session.schoolId,
      );
      if (tasks.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: filterCourses 过滤后无任务');
        return;
      }

      // 监听日志
      final logSub = reportService!.logStream.listen((e) {
        // ignore: avoid_print
        print('    [Report] ${e.message}');
      });

      try {
        await reportService!.executeBatch(tasks, cfg);
        // 不强校验 success, 只要没有未捕获异常即视为通过
      } finally {
        await logSub.cancel();
      }
    }, skip: noHarnessSkip(harness),
        timeout: const Timeout(Duration(minutes: 3)));
  });
}
