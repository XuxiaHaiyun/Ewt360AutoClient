// AnswerService 端到端测试 (真实网关, 需 test/accounts.json)
//
// 复用 [AnswerService] 验证完整答案获取流程:
//   - executeBatch (direct 方案) - 端到端真实拉取首个课程的答案
//
// 注意:
//   - 使用首个有 paperId 的课程测试, 避免大量 API 调用
//   - 不测试 reportId 方案的 submitPaper 步骤 (有副作用: 试卷标记为已提交)
//   - 不测试 favorites 方案 (会污染用户收藏夹)
//   - applyFilter 纯函数测试已移至 test/unit/logic/filters_test.dart
import 'package:ewt_auto_client/features/answer/domain/entities/answer_filter_config.dart';
import 'package:ewt_auto_client/features/answer/presentation/services/answer_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  AnswerService? answerService;

  // 共享状态
  String homeworkId = '';
  List<Map<String, dynamic>> courses = [];

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    if (h == null) return;
    answerService = AnswerService(client: h.client);

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
    answerService?.dispose();
    harness?.dispose();
  });

  group('AnswerService.executeBatch - 端到端真实答案获取', () {
    test('direct 方案 - 单课程答案获取', () async {
      if (homeworkId.isEmpty || courses.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId 或课程');
        return;
      }

      // 找一个有 paperId 的课程 (优先 contentType=2 试卷)
      Map<String, dynamic>? targetCourse;
      for (final c in courses) {
        final ct = c['contentType'];
        if (ct == 2 || ct == '2') {
          targetCourse = c;
          break;
        }
      }
      // 回退: 第一个课程
      targetCourse ??= courses.first;

      // 监听日志输出
      final logSub = answerService!.logStream.listen((e) {
        // ignore: avoid_print
        print('    [AnswerService] ${e.message}');
      });

      try {
        final results = await answerService!.executeBatch(
          [targetCourse],
          homeworkId: homeworkId,
          schoolId: harness!.session.schoolId,
          method: 'direct',
        );
        expect(results, isA<List>());
        // 至少要返回结果对象 (即使题目数为 0)
        if (results.isNotEmpty) {
          final r = results.first;
          // ignore: avoid_print
          print('  结果: ${r.courseTitle} - '
              '${r.successCount}/${r.totalCount} 题, '
              'method=${r.method}, paperId=${r.paperId}');
          expect(r.courseTitle, isNotEmpty);
        } else {
          // ignore: avoid_print
          print('  (该课程无 paperId, 返回空结果 - 预期)');
        }
      } finally {
        await logSub.cancel();
      }
    }, skip: noHarnessSkip(harness),
        timeout: const Timeout(Duration(minutes: 2)));

    test('executeBatch 接受 AnswerFilterConfig 应用过滤', () async {
      if (homeworkId.isEmpty || courses.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId 或课程');
        return;
      }

      final logSub = answerService!.logStream.listen((e) {
        // ignore: avoid_print
        print('    [AnswerService] ${e.message}');
      });

      try {
        // 过滤配置: 过滤无作业 + 仅试卷类
        const cfg = AnswerFilterConfig(
          filterNoHomework: true,
          selectedTypes: [2], // 试卷
        );
        final results = await answerService!.executeBatch(
          courses,
          homeworkId: homeworkId,
          schoolId: harness!.session.schoolId,
          method: 'direct',
          filterConfig: cfg,
        );
        // ignore: avoid_print
        print('  过滤后结果数: ${results.length} (原 ${courses.length} 课程)');
      } finally {
        await logSub.cancel();
      }
    }, skip: noHarnessSkip(harness),
        timeout: const Timeout(Duration(minutes: 3)));
  });
}
