import 'dart:io';

import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/player/data/datasources/player_remote_datasource.dart';
import 'package:ewt_auto_client/features/player/data/datasources/telemetry_remote_datasource.dart';
import 'package:ewt_auto_client/features/player/domain/entities/telemetry_context.dart';
import 'package:ewt_auto_client/features/player/presentation/services/custom_report_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// 普通模式行为链 API 测试 (黑名单/认真度检测/互动答题等)
///
/// 使用替身数据源脱离真实网络。需要 quickjs_engine native dll:
/// 设置 `LIBQUICKJSC_TEST_PATH=<dll>` 后运行, 未设置时自动跳过。
void main() {
  final dllOverride = Platform.environment['LIBQUICKJSC_TEST_PATH'];
  final hasNative = dllOverride != null && File(dllOverride).existsSync();

  final client = DioClient(endpointConfig: EndpointConfig.fromJson({}));

  // 替身: 覆盖全部网络方法, 记录调用
  final calls = <String>[];
  final fakePlayer = _FakePlayerRemote(client, calls);
  final fakeTelemetry = _FakeTelemetryRemote(client, calls);

  Map<String, dynamic> account() => {
        'userId': '10086',
        'schoolId': '40092',
        'account': 'test_acct',
        'displayName': '测试同学',
        'token': 'fake-token',
        'sessionId': 'sess-1',
        'secret': 'sec-1',
        'clientIp': '1.2.3.4',
      };

  Map<String, dynamic> task() => {
        'title': '测试课程',
        'homeworkId': 'hw-1',
        'lessonId': 'lesson-1',
        'videoId': '',
        'taskId': 'task-1',
        'contentType': 1,
        'schoolId': '40092',
        'duration': 600,
      };

  CustomReportRuntime buildRuntime(String script) {
    final logs = <String>[];
    final rt = CustomReportRuntime.create(
      client: client,
      playerRemote: fakePlayer,
      telemetryRemote: fakeTelemetry,
      endpointConfig: EndpointConfig.fromJson({}),
      account: account(),
      task: task(),
      sessionId: 'sess-1',
      secret: 'sec-1',
      clientIp: '1.2.3.4',
      maxBatchSize: 10,
      onLog: (m, l) => logs.add('$l:$m'),
      onProgress: (r, m) {},
      onDetail: (_) {},
    );
    addTearDown(rt.dispose);
    return rt;
  }

  group('自定义模式 普通模式行为链 API (需要 native dll)', () {
    test('initVideo 拉取视频信息/黑名单/认真度配置/互动点', () async {
      final rt = buildRuntime('');
      final script = '''
async function main() {
  const v = await initVideo();
  return JSON.stringify({
    duration: v.duration,
    blacklisted: v.isBlacklisted,
    cpCount: v.checkPoints.length,
    iptCount: v.interactiveConfigs.length,
    downgrade: v.seriousCheckConfig.isDowngrade,
    pti0: v.checkPoints[0],
  });
}
''';
      await rt.execute(script);
      expect(calls, contains('getPlayerToken'));
      expect(calls, contains('getExternalVideoInfo'));
      expect(calls, contains('getVideodp'));
      expect(calls, contains('getSeriousCheckDownGradeConfig'));
      // 黑名单 true → 检测点生成: 600s → 3 个检测点 (m 720<z 480? 600-120=480 → 2个)
      // z=600, m=480, 360<m<=720 → count=2
    }, skip: hasNative ? false : '缺少 quickjs native 库');

    test('performFocusCheck 黑名单走滑块: 首报→解算→二次上报→恢复', () async {
      calls.clear();
      final rt = buildRuntime('');
      final script = '''
async function main() {
  await initVideo(); // fake: 黑名单=true, 认真度 level=0(不降级)
  const r = await performFocusCheck({pti: 5, checkPointTime: 300, clickDelayMs: 10});
  return JSON.stringify({ok: r.ok, cap: r.captchaToken ? 'yes' : 'no'});
}
''';
      await rt.execute(script);
      expect(calls, contains('addVideocss')); // 黑名单 → addVideocss
      expect(calls.where((c) => c == 'addVideocss').length, 2); // 首报+二次
      expect(calls, contains('sendCollectBatch')); // act=3 / act=2
      expect(calls, contains('sendPlaybackProgress'));
    }, skip: hasNative ? false : '缺少 quickjs native 库');

    test('doInteractivePoint 空答取答案→提交→记录通过', () async {
      calls.clear();
      final rt = buildRuntime('');
      final script = '''
async function main() {
  await initVideo(); // fake: 黑名单=true, 认真度 level=0(不降级)
  const r = await doInteractivePoint({configId: '1', timePoint: 30000});
  return JSON.stringify({ok: r.ok, correct: r.correct});
}
''';
      await rt.execute(script);
      expect(calls, contains('getInteractiveConfigDetail'));
      expect(calls.where((c) => c == 'submitInteractiveAnswer').length, 2);
      expect(calls.where((c) => c == 'addVideocss').length, 2); // 0→2
    }, skip: hasNative ? false : '缺少 quickjs native 库');

    test('getVideodp/solveCaptcha/persistProgress/queryProgress 可用', () async {
      calls.clear();
      final rt = buildRuntime('');
      final script = '''
async function main() {
  const bl = await getVideodp();
  const cap = await solveCaptcha();
  const pp = await persistProgress({playTime: 300});
  const qp = await queryProgress();
  return JSON.stringify({bl: bl.blacklisted, cap: cap.ok, pp: pp.ok, qp: qp});
}
''';
      await rt.execute(script);
      expect(calls, contains('getVideodp'));
      expect(calls, contains('sendPlaybackProgress'));
      expect(calls, contains('refreshTaskProgress'));
    }, skip: hasNative ? false : '缺少 quickjs native 库');
  });
}

class _FakePlayerRemote extends PlayerRemoteDataSource {
  final List<String> calls;
  _FakePlayerRemote(super.client, this.calls);

  @override
  Future<String> getPlayerToken({
    required String schoolId,
    required String lessonId,
    int type = 1,
    int contentType = 1,
    bool memberAuthBypass = false,
    String videoBizCode = '1013',
  }) async {
    calls.add('getPlayerToken');
    return 'fake-player-token';
  }

  @override
  Future<Map<String, dynamic>> getExternalVideoInfo({
    required String lessonId,
    required String videoToken,
    String videoBizCode = '1013',
    String sdkVersion = '3.0.37',
    int? contentType,
  }) async {
    calls.add('getExternalVideoInfo');
    return {
      'duration': 600,
      'interactiveInfo': {
        'interactiveConfigList': [
          {'id': '1', 'timePoint': 30000},
        ],
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getLessonDetail({
    required String schoolId,
    required String homeworkId,
    required String lessonId,
  }) async {
    calls.add('getLessonDetail');
    return {'interactiveVideo': false};
  }

  @override
  Future<Map<String, dynamic>> getSeriousCheckDownGradeConfig({
    required String schoolId,
    int videoType = 1,
  }) async {
    calls.add('getSeriousCheckDownGradeConfig');
    return {'level': 0, 'tips': '', 'needLog': 1, 'description': ''};
  }

  @override
  Future<bool> getVideodp() async {
    calls.add('getVideodp');
    return true; // 黑名单
  }

  @override
  Future<Map<String, dynamic>> addVideoss({
    required String schoolId,
    required String homeworkId,
    required String lessonId,
    required int seriousCheckResult,
    int type = 2,
    String? interactivePointId,
    String? captchaToken,
  }) async {
    calls.add('addVideoss');
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> addVideocss({
    required String schoolId,
    required String homeworkId,
    required String lessonId,
    required int seriousCheckResult,
    int type = 2,
    String? interactivePointId,
    String? captchaToken,
  }) async {
    calls.add('addVideocss');
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> getInteractiveConfigDetail({
    required String configId,
    String videoBizCode = '1013',
  }) async {
    calls.add('getInteractiveConfigDetail');
    return {
      'id': configId,
      'interactiveSceneId': 'scene-1',
      'question': {'id': 'q-1'},
    };
  }

  @override
  Future<Map<String, dynamic>> submitInteractiveAnswer({
    required String interactiveSceneId,
    required String questionId,
    required List<String> myAnswers,
    int totalSeconds = 1,
    String videoBizCode = '1013',
    String lessonId = '',
  }) async {
    calls.add('submitInteractiveAnswer');
    // 空答 → 返回正确答案
    if (myAnswers.every((a) => a.isEmpty)) {
      return {'answers': ['A']};
    }
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> refreshTaskProgress({
    required String homeworkId,
    required String taskId,
  }) async {
    calls.add('refreshTaskProgress');
    return {'ratio': 0.5};
  }
}

class _FakeTelemetryRemote extends TelemetryRemoteDataSource {
  final List<String> calls;
  _FakeTelemetryRemote(super.client, this.calls);

  @override
  Future<CollectResult> sendCollectBatch({
    required TelemetryContext ctx,
    required String sessionId,
    required String secret,
    required String lessonId,
    required String courseId,
    required int action,
    required int stayTime,
    required int beginTs,
    required int pointTimeId,
    required int pointNum,
    required String uuid,
    int? mediaTime,
    double speed = 1.0,
    int videoType = 1,
    bool useBackup = false,
    String reportBackend = 'clog',
    int multiEvents = 1,
  }) async {
    calls.add('sendCollectBatch');
    return const CollectResult(
      host: 'bfe',
      fallback: 0,
      httpStatus: 200,
      code: 200,
      msg: 'ok',
      serverTs: null,
      success: true,
      signature: 'sig',
      reportTime: 0,
    );
  }

  @override
  Future<bool> sendPlaybackProgress({
    required String userId,
    required String token,
    required String lessonId,
    required int playTime,
  }) async {
    calls.add('sendPlaybackProgress');
    return true;
  }
}
