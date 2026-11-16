// 提交试卷-获取题目端到端测试 (真实网关, 账号直登)
//
// 验证"提交试卷"功能的题目获取链路 (对应 SubmitPaperHelper 阶段1):
//   - 密码登录获取 token (默认账号可在环境变量 TEST_ACCOUNT/TEST_PASSWORD 覆盖)
//   - 复用 AnswerService.executeBatch (method=direct)
//   - 固定请求间隔 1s、逐题串行 (analysisWorkers=1)、日志不含"获取答案/方案"
//
// 本测试不依赖 test/accounts.json, 直接使用内置账号登录。
import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/answer/presentation/services/answer_service.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:ewt_auto_client/features/homework/data/datasources/homework_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

// 提交试卷测试账号 (默认, 可通过 --dart-define 覆盖)
const String _kAccount = String.fromEnvironment(
  'TEST_ACCOUNT',
  defaultValue: 'mzv509010370',
);
const String _kPassword = String.fromEnvironment(
  'TEST_PASSWORD',
  defaultValue: 'lh123456',
);

/// 可指定目标 paperId, 用于复现"无 reportId 的 205 试卷逐题查询失败"场景,
/// 为空时自动挑选首个试卷课程。
const String _kTargetPaperId = String.fromEnvironment(
  'TEST_PAPER_ID',
  defaultValue: '',
);

/// 用页面 URL 构造课程 (contentUrl 含真实 reportId/bizCode/homeworkId),
/// 直接验证 paperQuestionGroup 独立取题 (复现非谓语 205 试卷)。
const String _kPageUrl = String.fromEnvironment(
  'TEST_PAGE_URL',
  defaultValue:
      'https://web.ewt360.com/answer-pc/exam/answer?bizCode=205&homeworkId=10495545&paperId=2272824425949438563&platform=1&reportId=2346365243984331148&videoPoint=1',
);

/// bizCode=204 重复答题页 (contentUrl 无 reportId, 需模拟页面打开解析):
/// 对齐 answer-pc 打开时先 report(bizCode=204) 换取真实 reportId,
/// 再 paperQuestionGroup 独立取题。
const String _kPageUrl204 = String.fromEnvironment(
  'TEST_PAGE_URL_204',
  defaultValue:
      'https://web.ewt360.com/answer-pc/exam/answer?paperId=1728345383093494254&bizCode=204&platform=1&isRepeat=1',
);

void main() {
  DioClient? client;
  AnswerService? answerService;

  // 共享状态
  String schoolId = '';
  String homeworkId = '';
  List<Map<String, dynamic>> courses = [];
  String? loginError;

  setUpAll(() async {
    try {
      final endpointConfig = EndpointConfig.defaults();
      client = DioClient(endpointConfig: endpointConfig);
      final authRemote = AuthRemoteDataSource(client!);

      // 1. 密码登录
      final loginData = await authRemote.loginWithPassword(
        userName: _kAccount,
        password: _kPassword,
      );
      final token = loginData['token']?.toString() ?? '';
      if (token.isEmpty) {
        loginError = '登录成功但未返回 token';
        return;
      }
      client!.token = token;

      // 2. 获取 schoolId (提交试卷参数需要)
      try {
        final info = await authRemote.getSchoolUserInfo();
        schoolId = info['schoolId']?.toString() ?? '';
      } catch (e) {
        // ignore: 学校信息解析失败由后续断言报告
      }

      // 3. 拉取作业与课程列表
      //    该账号下 getHomeworkList(status=2) 返回空, 实际作业在
      //    status=0 / 3 (未开始/已结束), 故依次尝试多个 status。
      final hwRemote = HomeworkRemoteDataSource(client!);
      for (final status in [0, 3, 2, null]) {
        List<Map<String, dynamic>>? homeworkList;
        try {
          homeworkList = (await hwRemote.getHomeworkList(
            schoolId: schoolId,
            status: status,
            pageIndex: 1,
            pageSize: 20,
          )).whereType<Map<String, dynamic>>().toList();
        } catch (_) {
          continue;
        }
        if (homeworkList.isEmpty) continue;

        // 从首个作业逐日展开课程任务
        String hwId = '';
        for (final h in homeworkList) {
          hwId = (h['homeworkId'] ?? h['id'] ?? '').toString();
          if (hwId.isEmpty) continue;

          Map<String, dynamic> stat = const {};
          try {
            stat = await hwRemote.getDaySubjectStat(
              homeworkId: hwId,
              schoolId: schoolId,
            );
          } catch (_) {}
          final dateStat = (stat['dateStat'] as List<dynamic>?) ?? [];
          for (final day in dateStat) {
            if (day is! Map<String, dynamic>) continue;
            final dayId = (day['dateId'] ?? '').toString();
            if (dayId.isEmpty) continue;
            try {
              final result = await hwRemote.getHomeworkTasks(
                homeworkId: hwId,
                schoolId: schoolId,
                dayId: dayId,
                pageIndex: 1,
                pageSize: 50,
              );
              final data = (result['data'] as List<dynamic>?) ?? [];
              for (final c in data) {
                if (c is Map<String, dynamic>) {
                  c['homeworkId'] = hwId;
                  c['schoolId'] = schoolId;
                  courses.add(c);
                }
              }
            } catch (_) {}
            if (courses.isNotEmpty) break;
          }
          if (courses.isNotEmpty) break;
        }

        if (courses.isNotEmpty) {
          homeworkId = hwId;
          break;
        }
      }

      answerService = AnswerService(client: client!);
      // ignore: avoid_print
      print(
        'setUpAll: 账号=$_kAccount, schoolId=$schoolId, '
        'homeworkId=$homeworkId, 课程数=${courses.length}',
      );
    } catch (e) {
      loginError = '$e';
      // ignore: avoid_print
      print('setUpAll 登录失败: $e');
    }
  });

  tearDownAll(() {
    answerService?.dispose();
    client?.token = null;
  });

  group('提交试卷 - 获取题目 (escalation, 1s 间隔, 串行)', () {
    test('获取首个试卷课程的题目 (含题目/子题/答案字段)', () async {
      if (loginError != null || homeworkId.isEmpty || courses.isEmpty) {
        // ignore: avoid_print
        print(
          '  ⊘ 跳过: loginError=$loginError, homeworkId=$homeworkId, '
          '课程数=${courses.length}',
        );
        return;
      }

      // 优先挑选试卷课程 (contentType=2), 与"提交试卷"只支持已作答试卷一致;
      // 指定 TEST_PAPER_ID 时优先匹配对应 paperId
      Map<String, dynamic>? target;
      if (_kTargetPaperId.isNotEmpty) {
        for (final c in courses) {
          if ((c['paperId'] ?? '').toString() == _kTargetPaperId ||
              (c['contentUrl'] ?? c['content_url'] ?? '').toString().contains(
                _kTargetPaperId,
              )) {
            target = c;
            break;
          }
        }
      }
      target ??= (() {
        for (final c in courses) {
          if (c['contentType'] == 2 || c['contentType'] == '2') return c;
        }
        return null;
      })();
      target ??= courses.first;

      // 监听日志输出
      final logSub = answerService!.logStream.listen((e) {
        // ignore: avoid_print
        print('  [提交试卷] [${e.level}] ${e.message}');
      });

      try {
        final results = await answerService!.executeBatch(
          [target],
          homeworkId: homeworkId,
          schoolId: schoolId,
          method: 'escalation',
          // 提交试卷优化配置
          courseInterval: const Duration(seconds: 1),
          analysisWorkers: 1,
          neutralLog: true,
        );

        expect(results, isA<List>());
        if (results.isEmpty) {
          // ignore: avoid_print
          print('  (该课程无 paperId, 返回空结果 - 预期)');
          return;
        }

        final r = results.first;
        // ignore: avoid_print
        print(
          '  结果: ${r.courseTitle} - ${r.successCount}/${r.totalCount} 题, '
          'method=${r.method}, paperId=${r.paperId}, reportId=${r.reportId}',
        );
        expect(r.courseTitle, isNotEmpty);
        expect(r.paperId, isNotEmpty);

        if (r.questions.isNotEmpty) {
          // 抽样打印前 3 题, 确认题型/题干/选项字段已获取
          for (var i = 0; i < r.questions.length && i < 3; i++) {
            final q = r.questions[i];
            // ignore: avoid_print
            print(
              '    #${q.number} 题型=${q.questionType} '
              '选择题=${q.options.length} 子题数=${q.childQuestions.length} '
              '题干=${q.questionContent.length > 40 ? q.questionContent.substring(0, 40) : q.questionContent}',
            );
          }
        }
      } finally {
        await logSub.cancel();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  test(
    '页面URL直连 paperQuestionGroup 独立取题 (无逐题查询, 供手动填写)',
    () async {
      if (loginError != null) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 登录失败');
        return;
      }

      // 用页面 URL 构造课程, 复用 _fetchAnswers 的 contentUrl 参数解析
      final target = <String, dynamic>{
        'contentType': 2,
        'title': '页面URL取题',
        'contentUrl': _kPageUrl,
      };

      final logLines = <String>[];
      final logSub = answerService!.logStream.listen((e) {
        logLines.add(e.message);
        // ignore: avoid_print
        print('  [提交试卷] [${e.level}] ${e.message}');
      });

      try {
        final results = await answerService!.executeBatch(
          [target],
          homeworkId: '',
          schoolId: '',
          method: 'questions',
          courseInterval: const Duration(seconds: 1),
          analysisWorkers: 1,
          neutralLog: true,
        );

        expect(results, isNotEmpty);
        final r = results.first;
        // ignore: avoid_print
        print(
          '  结果: ${r.courseTitle} - ${r.successCount}/${r.totalCount} 题, '
          'method=${r.method}, reportId=${r.reportId}, bizCode=${r.bizCode}',
        );
        expect(r.paperId, '2272824425949438563');
        expect(r.method, 'questions');
        expect(r.successCount > 0, isTrue);

        // 核心断言: 走独立取题路径, 不应出现"逐题查询/并发查询"字样
        final joined = logLines.join('\n');
        // ignore: avoid_print
        print(
          '  日志包含 paperQuestionGroup: ${joined.contains('paperQuestionGroup')}',
        );
        expect(joined.contains('逐题查询'), isFalse, reason: '独立取题不应逐题查询标题');
        expect(joined.contains('并发'), isFalse, reason: '独立取题不应并发逐题查询');
      } finally {
        await logSub.cancel();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '204重复答题页 无reportId 解析后 paperQuestionGroup 独立取题',
    () async {
      if (loginError != null) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 登录失败');
        return;
      }

      // bizCode=204 页 URL 无 reportId, 仅 bizCode=204&isRepeat=1,
      // 独立取题路径需先 report(204) 换取真实 reportId 再 paperQuestionGroup。
      final target = <String, dynamic>{
        'contentType': 2,
        'title': '204重复答题取题',
        'contentUrl': _kPageUrl204,
      };

      final logLines = <String>[];
      final logSub = answerService!.logStream.listen((e) {
        logLines.add(e.message);
        // ignore: avoid_print
        print('  [提交试卷] [${e.level}] ${e.message}');
      });

      try {
        final results = await answerService!.executeBatch(
          [target],
          homeworkId: '',
          schoolId: '',
          method: 'questions',
          courseInterval: const Duration(seconds: 1),
          analysisWorkers: 1,
          neutralLog: true,
        );

        expect(results, isNotEmpty);
        final r = results.first;
        // ignore: avoid_print
        print(
          '  结果: ${r.courseTitle} - ${r.successCount}/${r.totalCount} 题, '
          'method=${r.method}, reportId=${r.reportId}, bizCode=${r.bizCode}',
        );
        expect(r.paperId, '1728345383093494254');
        expect(r.method, 'questions');
        expect(r.bizCode, '204');
        expect(r.successCount > 0, isTrue, reason: '204 页应经 report 解析后独立取到题目');

        // 核心断言: 走独立取题路径, 不应出现"逐题查询/并发查询"字样
        final joined = logLines.join('\n');
        expect(joined.contains('逐题查询'), isFalse, reason: '独立取题不应逐题查询标题');
        expect(joined.contains('并发'), isFalse, reason: '独立取题不应并发逐题查询');
      } finally {
        await logSub.cancel();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
