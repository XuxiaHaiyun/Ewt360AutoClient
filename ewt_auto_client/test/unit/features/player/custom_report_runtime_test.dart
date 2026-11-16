import 'dart:io';

import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/player/data/datasources/player_remote_datasource.dart';
import 'package:ewt_auto_client/features/player/data/datasources/telemetry_remote_datasource.dart';
import 'package:ewt_auto_client/features/player/presentation/dialogs/task_progress_dialog.dart';
import 'package:ewt_auto_client/features/player/presentation/services/custom_report_runtime.dart';
import 'package:ewt_auto_client/features/player/presentation/services/custom_report_runtime_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自定义上报脚本运行时冒烟测试
///
/// 需要 quickjs_engine 的 native 库: 设置环境变量
/// `LIBQUICKJSC_TEST_PATH=<dll 绝对路径>` 后运行。未设置时自动跳过。
void main() {
  final dllOverride = Platform.environment['LIBQUICKJSC_TEST_PATH'];
  final hasNative = dllOverride != null && File(dllOverride).existsSync();

  final client = DioClient(endpointConfig: EndpointConfig.fromJson({}));

  Map<String, dynamic> account() => {
        'userId': '10086',
        'schoolId': '40092',
        'account': 'test_acct',
        'displayName': '测试同学',
        'schoolName': '测试学校',
        'provinceCode': '130000',
        'mobile': '13800000000',
        'token': 'fake-token-123',
        'sessionId': 'sess-1',
        'secret': 'sec-1',
        'clientIp': '1.2.3.4',
        'maxBatchSize': 10,
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

  CustomReportRuntime buildRuntime({
    required String script,
    required void Function(String msg, LogLevel level) onLog,
    required void Function(double ratio, String? message) onProgress,
  }) {
    final rt = CustomReportRuntime.create(
      client: client,
      playerRemote: PlayerRemoteDataSource(client),
      telemetryRemote: TelemetryRemoteDataSource(client),
      endpointConfig: EndpointConfig.fromJson({}),
      account: account(),
      task: task(),
      sessionId: 'sess-1',
      secret: 'sec-1',
      clientIp: '1.2.3.4',
      maxBatchSize: 10,
      onLog: onLog,
      onProgress: onProgress,
      onDetail: (_) {},
    );
    addTearDown(rt.dispose);
    return rt;
  }

  group('CustomReportRuntime (需要 native dll)', () {
    test('脚本可访问 account/task 字段并调用 log/updateProgress/parseJson/getSession',
        () async {
      final logs = <String>[];
      final progresses = <double>[];
      final rt = buildRuntime(
        script: '',
        onLog: (m, l) => logs.add('$l:$m'),
        onProgress: (r, m) => progresses.add(r),
      );

      final script = '''
function main() {
  log('hello ' + account.account);
  updateProgress(0.5, 'half');
  var p = parseJson('{"a":1}');
  var s = getSession();
  return JSON.stringify({p: p, s: s.sessionId, name: task.title, uid: account.userId});
}
''';
      await rt.execute(script);
      expect(logs, contains('LogLevel.info:hello test_acct'));
      expect(progresses, [0.5]);
      // 冒烟: 无异常即通过 (返回值通过日志/进度回调断言)
    }, skip: hasNative ? false : '缺少 quickjs native 库 (LIBQUICKJSC_TEST_PATH)');

    test('async main 支持 await sleep 与 updateProgress', () async {
      final logs = <String>[];
      final progresses = <double>[];
      final rt = buildRuntime(
        script: '',
        onLog: (m, l) => logs.add(m),
        onProgress: (r, m) => progresses.add(r),
      );

      final script = '''
async function main() {
  log('start');
  await sleep(80);
  log('after-sleep');
  updateProgress(1.0, 'done');
}
''';
      await rt.execute(script, totalTimeout: const Duration(seconds: 10));
      expect(logs, contains('start'));
      expect(logs, contains('after-sleep'));
      expect(progresses, [1.0]);
    }, skip: hasNative ? false : '缺少 quickjs native 库 (LIBQUICKJSC_TEST_PATH)');

    test('脚本语法错误抛出 ScriptRuntimeException', () async {
      final rt = buildRuntime(
        script: '',
        onLog: (m, l) {},
        onProgress: (r, m) {},
      );
      expect(
        () => rt.execute('function main( {'),
        throwsA(isA<ScriptRuntimeException>()),
      );
    }, skip: hasNative ? false : '缺少 quickjs native 库 (LIBQUICKJSC_TEST_PATH)');
  });
}
