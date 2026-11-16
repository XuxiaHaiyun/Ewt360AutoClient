/// 测试账号加载器与集成测试公共辅助
///
/// 从 test/accounts.json 加载真实账号配置, 构建可复用的 [DioClient] 和 [UserSession]。
/// 复用项目核心层 (EndpointConfig + DioClient + AuthInterceptor + SignInterceptor),
/// 不做任何 mock, 确保测试链路与生产环境一致。
///
/// accounts.json 支持两种格式:
///   1. 字符串数组 (仅 token): ["token1", "token2"]
///      缺失的 userId/schoolId 会通过 getUser + getSchoolUserInfo 在线补全
///   2. UserSession JSON 对象数组 (推荐, 字段完整, 避免额外 API 调用)
///
/// 用法 (推荐, 无账号时自动 skip 整个测试文件):
/// ```dart
/// TestHarness? harness;
/// setUpAll(() async { harness = await loadTestHarnessOrNull(); });
/// tearDownAll(() => harness?.dispose());
/// // 每个 test 追加: skip: noHarnessSkip(harness)
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:ewt_auto_client/features/homework/data/datasources/homework_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试夹具: 持有已配置好 token 的 DioClient 与对应 UserSession
class TestHarness {
  final EndpointConfig endpointConfig;
  final DioClient client;
  final UserSession session;

  TestHarness({
    required this.endpointConfig,
    required this.client,
    required this.session,
  });

  /// 释放资源 (DioClient 持有 Dio, 关闭底层 HttpClient)
  void dispose() {
    client.token = null;
  }
}

/// 加载 test/accounts.json 并构建 [TestHarness]。
///
/// 若文件缺失/为空/token 无效, 抛出 [StateError], 触发测试 skip。
Future<TestHarness> loadTestHarness() async {
  final file = File('test/accounts.json');
  if (!file.existsSync()) {
    throw StateError('test/accounts.json 不存在');
  }
  final raw = file.readAsStringSync().trim();
  if (raw.isEmpty) {
    throw StateError('test/accounts.json 为空');
  }

  final dynamic parsed = jsonDecode(raw);
  if (parsed is! List || parsed.isEmpty) {
    throw StateError('test/accounts.json 必须是非空数组');
  }

  final first = parsed.first;
  UserSession session;
  if (first is String) {
    // 兼容旧格式: 纯 token 字符串数组
    // 缺失的 userId/schoolId 通过 API 在线补全
    session = await _resolveSessionFromToken(first);
  } else if (first is Map<String, dynamic>) {
    session = UserSession.fromJson(first);
  } else {
    throw StateError('accounts.json 第一项格式不支持: ${first.runtimeType}');
  }

  if (session.token.isEmpty) {
    throw StateError('accounts.json 中 token 为空');
  }

  // 构建与生产代码完全一致的 EndpointConfig + DioClient
  final endpointConfig = EndpointConfig.defaults();
  final client = DioClient(endpointConfig: endpointConfig);
  client.token = session.token;

  return TestHarness(
    endpointConfig: endpointConfig,
    client: client,
    session: session,
  );
}

/// 加载账号, 失败返回 null (不抛异常)。
///
/// 供 `setUpAll` 使用: 无账号/账号无效时静默降级,
/// 配合 [noHarnessSkip] 让整个测试文件优雅 skip。
Future<TestHarness?> loadTestHarnessOrNull() async {
  try {
    return await loadTestHarness();
  } catch (_) {
    return null;
  }
}

/// 生成 skip 原因: harness 为 null 时返回提示, 否则返回 false (不跳过)。
///
/// 用法: `test('...', () async {...}, skip: noHarnessSkip(harness));`
String? noHarnessSkip(TestHarness? harness) =>
    harness == null ? '需要 test/accounts.json 配置有效账号' : null;

/// 预取首个作业并解析其课程列表 (作业 → 每日统计 → 课程链路)。
///
/// 多个 API 集成测试 (homework/player/answer/download/progress) 都需要
/// 从真实账号拉取作业与课程, 本函数统一该流程, 消除重复样板。
///
/// 返回 record: (homeworkId, dayId, courses)。
/// courses 已注入 homeworkId/schoolId 字段 (供 AnswerService/DownloadService 使用)。
/// 任一环节无数据时返回空字段, 由调用方 skip。
Future<({String homeworkId, String dayId, List<Map<String, dynamic>> courses})>
    prefetchHomeworkAndCourses(
  DioClient client,
  String schoolId, {
  int homeworkPageSize = 5,
  int coursePageSize = 50,
  int maxCourses = 5,
}) async {
  final hwRemote = HomeworkRemoteDataSource(client);
  var homeworkId = '';
  var dayId = '';
  final courses = <Map<String, dynamic>>[];

  final list = await hwRemote.getHomeworkList(
    schoolId: schoolId,
    status: 2,
    pageIndex: 1,
    pageSize: homeworkPageSize,
  );
  if (list.isEmpty) return (homeworkId: '', dayId: '', courses: courses);
  homeworkId =
      (list.first as Map<String, dynamic>)['homeworkId'].toString();

  final stat = await hwRemote.getDaySubjectStat(
    homeworkId: homeworkId,
    schoolId: schoolId,
  );
  final dateStat = (stat['dateStat'] as List<dynamic>?) ?? [];
  for (final day in dateStat) {
    if (day is! Map<String, dynamic>) continue;
    final dId = (day['dateId'] ?? '').toString();
    if (dId.isEmpty) continue;
    dayId = dId;
    final result = await hwRemote.getHomeworkTasks(
      homeworkId: homeworkId,
      schoolId: schoolId,
      dayId: dayId,
      pageIndex: 1,
      pageSize: coursePageSize,
    );
    final data = (result['data'] as List<dynamic>?) ?? [];
    for (final c in data) {
      if (c is Map<String, dynamic>) {
        c['homeworkId'] = homeworkId;
        c['schoolId'] = schoolId;
        courses.add(c);
        if (courses.length >= maxCourses) break;
      }
    }
    if (courses.isNotEmpty) break; // 取首日课程
  }

  return (homeworkId: homeworkId, dayId: dayId, courses: courses);
}

/// 当 accounts.json 仅有 token 时, 通过 AuthRemoteDataSource 在线补全 userId/schoolId。
///
/// 流程:
///   1. validateToken(token) → getUser.data (含 userId)
///   2. getSchoolUserInfo() → schoolUserInfo.data (含 schoolId)
Future<UserSession> _resolveSessionFromToken(String token) async {
  final endpointConfig = EndpointConfig.defaults();
  final client = DioClient(endpointConfig: endpointConfig);
  client.token = token;
  final authRemote = AuthRemoteDataSource(client);

  String userId = '';
  String schoolId = '';
  try {
    final userInfo = await authRemote.validateToken(token);
    userId = (userInfo['userId'] ?? userInfo['id'] ?? '').toString();
  } catch (_) {
    // ignore: validateToken 失败不阻断, 由后续测试报告
  }
  try {
    final schoolUserInfo = await authRemote.getSchoolUserInfo();
    schoolId = (schoolUserInfo['schoolId'] ?? schoolUserInfo['id'] ?? '').toString();
  } catch (_) {
    // ignore
  }
  client.token = null;

  return UserSession(
    token: token,
    userId: userId,
    schoolId: schoolId,
    displayName: '动态解析账号',
  );
}
