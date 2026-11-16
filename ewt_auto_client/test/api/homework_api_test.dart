// 作业 API 集成测试 (真实网关, 需 test/accounts.json)
//
// 复用 [HomeworkRemoteDataSource] 验证作业列表/统计/任务列表/课时详情/播放器令牌/视频信息接口。
// 使用 [prefetchHomeworkAndCourses] 统一预取首个作业与课程, 无有效账号时自动 skip。
import 'package:ewt_auto_client/features/homework/data/datasources/homework_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  HomeworkRemoteDataSource? hwRemote;

  // 测试间共享状态: 预取结果
  String homeworkId = '';
  String dayId = '';
  String lessonId = '';
  String courseTitle = '';

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    if (h == null) return;
    hwRemote = HomeworkRemoteDataSource(h.client);

    final prefetched = await prefetchHomeworkAndCourses(
      h.client,
      h.session.schoolId,
    );
    homeworkId = prefetched.homeworkId;
    dayId = prefetched.dayId;
    if (prefetched.courses.isNotEmpty) {
      final first = prefetched.courses.first;
      lessonId = (first['lessonId'] ?? first['contentId'] ?? '').toString();
      courseTitle = (first['title'] ?? first['lessonName'] ?? '').toString();
    }
    // ignore: avoid_print
    print('setUpAll: homeworkId=$homeworkId, dayId=$dayId, '
        'lessonId=$lessonId, courseTitle=$courseTitle');
  });
  tearDownAll(() => harness?.dispose());

  group('作业 API', () {
    test('getHomeworkList - 获取作业列表', () async {
      final list = await hwRemote!.getHomeworkList(
        schoolId: harness!.session.schoolId,
        status: 2, // 已开始未完成
        pageIndex: 1,
        pageSize: 5,
      );
      expect(list, isA<List>());
      // ignore: avoid_print
      print('  作业数: ${list.length}');
      if (list.isNotEmpty) {
        final first = list.first as Map<String, dynamic>;
        // ignore: avoid_print
        print('  首个作业: id=${first['homeworkId']}, '
            'name=${first['homeworkName'] ?? first['title']}');
      }
    }, skip: noHarnessSkip(harness));

    test('getDaySubjectStat - 获取每日科目统计', () async {
      if (homeworkId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId');
        return;
      }
      final stat = await hwRemote!.getDaySubjectStat(
        homeworkId: homeworkId,
        schoolId: harness!.session.schoolId,
      );
      expect(stat, isA<Map<String, dynamic>>());
      final dateStat = (stat['dateStat'] as List<dynamic>?) ?? [];
      // ignore: avoid_print
      print('  日期数: ${dateStat.length}');
    }, skip: noHarnessSkip(harness));

    test('getHomeworkTasks - 获取任务列表 (课程列表)', () async {
      if (homeworkId.isEmpty || dayId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId/dayId');
        return;
      }
      final result = await hwRemote!.getHomeworkTasks(
        homeworkId: homeworkId,
        schoolId: harness!.session.schoolId,
        dayId: dayId,
        pageIndex: 1,
        pageSize: 30,
      );
      expect(result, isA<Map<String, dynamic>>());
      final data = result['data'];
      expect(data, isA<List>());
      // ignore: avoid_print
      print('  课程数: ${(data as List).length}');
    }, skip: noHarnessSkip(harness));

    test('getLessonDetail - 获取课程讲次详情', () async {
      if (homeworkId.isEmpty || lessonId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId/lessonId');
        return;
      }
      final detail = await hwRemote!.getLessonDetail(
        schoolId: harness!.session.schoolId,
        lessonId: lessonId,
        homeworkId: homeworkId,
      );
      expect(detail, isA<Map<String, dynamic>>());
      // ignore: avoid_print
      print('  courseId=${detail['courseId']}, '
          'title=${detail['lessonName'] ?? detail['title']}');
    }, skip: noHarnessSkip(harness));

    test('getPlayerToken - 获取播放器 Token', () async {
      if (lessonId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 lessonId');
        return;
      }
      final token = await hwRemote!.getPlayerToken(
        schoolId: harness!.session.schoolId,
        lessonId: lessonId,
      );
      expect(token, isNotEmpty);
      // ignore: avoid_print
      print('  playerToken: ${token.length > 16 ? token.substring(0, 16) : token}...');
    }, skip: noHarnessSkip(harness));

    test('getExternalVideoInfo - 获取视频信息', () async {
      if (lessonId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 lessonId');
        return;
      }
      final playerToken = await hwRemote!.getPlayerToken(
        schoolId: harness!.session.schoolId,
        lessonId: lessonId,
      );
      if (playerToken.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: playerToken 为空');
        return;
      }
      final videoList = await hwRemote!.getExternalVideoInfo(
        lessonId: lessonId,
        videoToken: playerToken,
      );
      expect(videoList, isA<List>());
      // ignore: avoid_print
      print('  视频源数: ${videoList.length}');
      if (videoList.isNotEmpty) {
        final first = videoList.first as Map<String, dynamic>;
        // ignore: avoid_print
        print('  首个视频: duration=${first['duration']}s, '
            'showPlat=${first['showPlat']}');
      }
    }, skip: noHarnessSkip(harness));
  });
}
