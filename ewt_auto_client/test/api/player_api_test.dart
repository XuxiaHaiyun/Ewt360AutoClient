// 播放器 API 集成测试 (真实网关, 需 test/accounts.json)
//
// 复用 [PlayerRemoteDataSource] 验证:
//   - getPlayerGlobalConf (BFE session: secret/sessionId/clientIp)
//   - getSeriousCheckDownGradeConfig (认真度检测降级配置)
//   - getPlayerToken (类型严格 int 校验)
//   - getExternalVideoInfo (视频时长/视频列表)
//   - getLessonDetail (课时详情/courseId)
//   - getLessonTaskInfo (playTime/lessonTime)
//   - queryTaskProgress / refreshTaskProgress (任务进度查询)
import 'package:ewt_auto_client/features/player/data/datasources/player_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  PlayerRemoteDataSource? playerRemote;

  // 共享状态 (由 setUpAll 预取)
  String homeworkId = '';
  String lessonId = '';
  String taskId = '';
  String playerToken = '';

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    if (h == null) return;
    playerRemote = PlayerRemoteDataSource(h.client);

    final prefetched = await prefetchHomeworkAndCourses(
      h.client,
      h.session.schoolId,
    );
    homeworkId = prefetched.homeworkId;
    for (final c in prefetched.courses) {
      final lid = (c['lessonId'] ?? c['contentId'] ?? '').toString();
      if (lid.isEmpty) continue;
      lessonId = lid;
      taskId = (c['taskId'] ?? '').toString();
      break;
    }
    // ignore: avoid_print
    print('setUpAll: homeworkId=$homeworkId, lessonId=$lessonId, taskId=$taskId');
  });
  tearDownAll(() => harness?.dispose());

  group('播放器 API', () {
    test('getPlayerGlobalConf - 获取 BFE session', () async {
      final conf = await playerRemote!.getPlayerGlobalConf();
      expect(conf, isA<Map<String, dynamic>>());
      final globalInfo = (conf['globalInfo'] as Map<String, dynamic>?) ?? {};
      final sid = globalInfo['sessionId']?.toString() ?? '';
      // ignore: avoid_print
      print('  sessionId=${sid.length > 8 ? sid.substring(0, 8) : sid}..., '
          'secret=${globalInfo['secret'] != null ? "已获取" : "空"}, '
          'clientIp=${globalInfo['clientIp']}');
      expect(globalInfo['sessionId'], isNotNull);
    }, skip: noHarnessSkip(harness));

    test('getSeriousCheckDownGradeConfig - 认真度检测降级配置', () async {
      final cfg = await playerRemote!.getSeriousCheckDownGradeConfig(
        schoolId: harness!.session.schoolId,
      );
      expect(cfg, isA<Map<String, dynamic>>());
      // ignore: avoid_print
      print('  level=${cfg['level']}, needLog=${cfg['needLog']}, '
          'tips=${cfg['tips']}');
    }, skip: noHarnessSkip(harness));

    test('getPlayerToken - 获取播放 Token (int 类型严格校验)', () async {
      if (lessonId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 lessonId');
        return;
      }
      playerToken = await playerRemote!.getPlayerToken(
        schoolId: harness!.session.schoolId,
        lessonId: lessonId,
      );
      expect(playerToken, isNotEmpty);
      // ignore: avoid_print
      print('  playerToken: ${playerToken.length > 16 ? playerToken.substring(0, 16) : playerToken}...');
    }, skip: noHarnessSkip(harness));

    test('getExternalVideoInfo - 获取外部视频信息', () async {
      if (lessonId.isEmpty || playerToken.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 lessonId/playerToken');
        return;
      }
      final info = await playerRemote!.getExternalVideoInfo(
        lessonId: lessonId,
        videoToken: playerToken,
      );
      expect(info, isA<Map<String, dynamic>>());
      final videoList = (info['videoList'] as List<dynamic>?) ?? [];
      // ignore: avoid_print
      print('  视频源数: ${videoList.length}');
      if (videoList.isNotEmpty) {
        final first = videoList.first as Map<String, dynamic>;
        // ignore: avoid_print
        print('  duration=${first['duration']}s, '
            'showPlat=${first['showPlat']}');
      }
    }, skip: noHarnessSkip(harness));

    test('getLessonDetail - 获取课时详情 (含 courseId)', () async {
      if (homeworkId.isEmpty || lessonId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId/lessonId');
        return;
      }
      final detail = await playerRemote!.getLessonDetail(
        schoolId: harness!.session.schoolId,
        homeworkId: homeworkId,
        lessonId: lessonId,
      );
      expect(detail, isA<Map<String, dynamic>>());
      // ignore: avoid_print
      print('  courseId=${detail['courseId']}, '
          'lessonName=${detail['lessonName'] ?? detail['title']}');
    }, skip: noHarnessSkip(harness));

    test('getLessonTaskInfo - 课时任务信息 (playTime/lessonTime)', () async {
      if (homeworkId.isEmpty || lessonId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId/lessonId');
        return;
      }
      final info = await playerRemote!.getLessonTaskInfo(
        homeworkId: homeworkId,
        lessonId: lessonId,
        schoolId: harness!.session.schoolId,
      );
      expect(info, isA<Map<String, dynamic>>());
      // ignore: avoid_print
      print('  playTime=${info['playTime']}ms, '
          'lessonTime=${info['lessonTime']}ms, '
          'finishPercent=${info['finishPercent']}');
    }, skip: noHarnessSkip(harness));

    test('queryTaskProgress - 查询任务进度', () async {
      if (taskId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 taskId');
        return;
      }
      final results = await playerRemote!.queryTaskProgress(
        taskIds: [taskId],
        schoolId: harness!.session.schoolId,
      );
      expect(results, isA<List>());
      if (results.isNotEmpty) {
        final first = results.first;
        // ignore: avoid_print
        print('  ratio=${first['ratio']}, finishPercent=${first['finishPercent']}');
      }
    }, skip: noHarnessSkip(harness));

    test('refreshTaskProgress - 刷新任务进度', () async {
      if (taskId.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 taskId');
        return;
      }
      final result = await playerRemote!.refreshTaskProgress(
        homeworkId: homeworkId,
        taskId: taskId,
      );
      expect(result, isA<Map<String, dynamic>>());
      // ignore: avoid_print
      print('  ratio=${result['ratio']}, finishPercent=${result['finishPercent']}');
    }, skip: noHarnessSkip(harness));
  });
}
