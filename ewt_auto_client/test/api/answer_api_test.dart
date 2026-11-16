// 答案 API 集成测试 (真实网关, 需 test/accounts.json)
//
// 复用 [AnswerRemoteDataSource] 验证越权答案获取链路:
//   - getStudyGuideAndPractice (导学案 + paperId/reportId)
//   - getAnswerReport (bizCode=201 获取 reportId)
//   - getAnswerSheetSubGroup (题组题目列表)
//   - getAnswerPaper (bizCode=204 完整题目列表)
//   - getPaperQuestions (题目 ID 列表)
//   - getQuestionAnalysis (单题答案/解析)
//   - submitPaper (有副作用: 标记试卷为已提交, 仅做连通性验证, 不实际触发)
//
// 注意: 所有 answerprod API 需 Origin/Referer=web.ewt360.com,
// 已由 [AnswerRemoteDataSource._answerHeaders] 处理, 测试无需手动设置。
import 'package:ewt_auto_client/features/answer/data/datasources/answer_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  AnswerRemoteDataSource? answerRemote;

  // 共享状态 (由 setUpAll 预取)
  String homeworkId = '';
  String lessonId = '';
  String taskId = '';
  String paperId = '';
  String reportId = '';
  String questionId = '';

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    if (h == null) return;
    answerRemote = AnswerRemoteDataSource(h.client);

    // 预取首个课程, 解析 paperId/reportId/taskId/lessonId
    final prefetched = await prefetchHomeworkAndCourses(
      h.client,
      h.session.schoolId,
      maxCourses: 10,
    );
    homeworkId = prefetched.homeworkId;
    for (final c in prefetched.courses) {
      final lid = (c['lessonId'] ?? c['contentId'] ?? '').toString();
      if (lid.isEmpty) continue;
      lessonId = lid;
      taskId = (c['taskId'] ?? '').toString();
      break;
    }

    // 用 studyGuide 接口获取 paperId/reportId
    if (lessonId.isNotEmpty) {
      try {
        final sg = await answerRemote!.getStudyGuideAndPractice(
          schoolId: h.session.schoolId,
          homeworkId: homeworkId,
          taskIds: taskId.isNotEmpty ? [taskId] : [],
          lessonIds: [lessonId],
        );
        final list =
            (sg['list'] as List<dynamic>?) ?? (sg['data'] as List<dynamic>?) ?? [];
        for (final item in list) {
          if (item is! Map<String, dynamic>) continue;
          if (item['lessonId']?.toString() != lessonId) continue;
          final studyTest = item['studyTest'];
          if (studyTest is! Map<String, dynamic>) continue;
          paperId = (studyTest['paperId'] ?? '').toString();
          reportId = (studyTest['reportId'] ?? '').toString();
          if (paperId == '0') paperId = '';
          if (reportId == '0') reportId = '';
          if (paperId.isNotEmpty) break;
        }
      } catch (_) {}
    }
    // ignore: avoid_print
    print('setUpAll: homeworkId=$homeworkId, lessonId=$lessonId, '
        'paperId=$paperId, reportId=$reportId');
  });
  tearDownAll(() => harness?.dispose());

  group('答案 API', () {
    test('getStudyGuideAndPractice - 导学案与 paperId', () async {
      if (homeworkId.isEmpty || lessonId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId/lessonId');
        return;
      }
      final result = await answerRemote!.getStudyGuideAndPractice(
        schoolId: harness!.session.schoolId,
        homeworkId: homeworkId,
        taskIds: taskId.isNotEmpty ? [taskId] : [],
        lessonIds: [lessonId],
      );
      expect(result, isA<Map<String, dynamic>>());
      // ignore: avoid_print
      print('  字段: ${result.keys.toList().take(5)}');
    }, skip: noHarnessSkip(harness));

    test('getAnswerReport - bizCode=201 获取 reportId', () async {
      if (paperId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 paperId');
        return;
      }
      final result = await answerRemote!.getAnswerReport(
        paperId: paperId,
        bizCode: '201',
        homeworkId: '0',
      );
      expect(result['success'], isTrue);
      final data = result['data'];
      if (data is Map<String, dynamic>) {
        final rid = (data['reportId'] ?? '').toString();
        // ignore: avoid_print
        print('  reportId=${rid.isNotEmpty ? "${rid.substring(0, 8)}..." : "空"}');
        if (rid.isNotEmpty) reportId = rid;
      }
    }, skip: noHarnessSkip(harness));

    test('getAnswerSheetSubGroup - 题组题目列表', () async {
      if (paperId.isEmpty || reportId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 paperId/reportId');
        return;
      }
      final result = await answerRemote!.getAnswerSheetSubGroup(
        paperId: paperId,
        reportId: reportId,
        homeworkId: '0',
      );
      expect(result, isA<Map<String, dynamic>>());
      final data = result['data'];
      if (data is Map<String, dynamic>) {
        final groups = (data['groupQuestionList'] as List<dynamic>?) ?? [];
        int totalQ = 0;
        for (final g in groups) {
          if (g is Map<String, dynamic>) {
            final qList = (g['questionList'] as List<dynamic>?) ?? [];
            totalQ += qList.length;
            if (questionId.isEmpty && qList.isNotEmpty) {
              questionId =
                  (qList.first as Map<String, dynamic>)['questionId'].toString();
            }
          }
        }
        // ignore: avoid_print
        print('  groups=${groups.length}, questions=$totalQ');
      }
    }, skip: noHarnessSkip(harness));

    test('getAnswerPaper - bizCode=204 完整题目列表 (含题干)', () async {
      if (paperId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 paperId');
        return;
      }
      final result = await answerRemote!.getAnswerPaper(
        paperId: paperId,
        reportId: reportId,
        bizCode: '204',
      );
      expect(result, isA<Map<String, dynamic>>());
      final data = result['data'];
      if (data is Map<String, dynamic>) {
        final qs = (data['questions'] as List<dynamic>?) ?? [];
        // ignore: avoid_print
        print('  题目数: ${qs.length}');
        if (qs.isNotEmpty && questionId.isEmpty) {
          questionId = ((qs.first as Map<String, dynamic>)['id'] ??
                  (qs.first as Map<String, dynamic>)['questionId'])
              .toString();
        }
      }
    }, skip: noHarnessSkip(harness));

    test('getPaperQuestions - 题目 ID 列表', () async {
      if (paperId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 paperId');
        return;
      }
      final result = await answerRemote!.getPaperQuestions(paperId: paperId);
      expect(result, isA<Map<String, dynamic>>());
      final data = result['data'];
      if (data is Map<String, dynamic>) {
        final qs = (data['questionList'] as List<dynamic>?) ?? [];
        // ignore: avoid_print
        print('  题目数: ${qs.length}');
      }
    }, skip: noHarnessSkip(harness));

    test('getQuestionAnalysis - 单题答案解析', () async {
      if (paperId.isEmpty || reportId.isEmpty || questionId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 paperId/reportId/questionId');
        return;
      }
      final result = await answerRemote!.getQuestionAnalysis(
        paperId: paperId,
        reportId: reportId,
        questionId: questionId,
        bizCode: '201',
        homeworkId: '0',
      );
      expect(result, isA<Map<String, dynamic>>());
      final data = result['data'];
      if (data is Map<String, dynamic>) {
        // ignore: avoid_print
        print('  rightAnswer=${data['rightAnswer'] ?? "(空)"}, '
            'hasAnalyse=${data['analyse'] != null}');
      }
    }, skip: noHarnessSkip(harness));

    // submitPaper 有副作用 (试卷标记为已提交), 仅做接口连通性验证, 不使用真实 paperId
    test('submitPaper - 接口连通性 (paperId=0 预期失败)', () async {
      final result = await answerRemote!.submitPaper(
        paperId: '0',
        reportId: '0',
        homeworkId: '0',
      );
      expect(result, isA<Map<String, dynamic>>());
      // 预期: success=false, msg 包含错误信息
      // ignore: avoid_print
      print('  (预期失败) success=${result['success']}, '
          'msg=${result['message']}');
    }, skip: noHarnessSkip(harness));
  });
}
