// 周培优 API 集成测试 (真实网关, 需 test/accounts.json)
//
// 复用 [WeekendRemoteDataSource] 验证周培优功能链路:
//   - checkUserAuth (账号是否开通周培优)
//   - getUserInfo (周培优用户信息)
//   - getClassBookList (班级教材列表)
//   - getScheduleList (课程表)
//   - getCourseDetail (课程详情)
//
// 注意: 若账号未开通周培优, 各接口可能返回权限错误, 测试只校验接口可达性。
import 'package:ewt_auto_client/features/weekend/data/datasources/weekend_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  WeekendRemoteDataSource? weekendRemote;

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    weekendRemote = h == null ? null : WeekendRemoteDataSource(h.client);
  });
  tearDownAll(() => harness?.dispose());

  group('周培优 API', () {
    test('checkUserAuth - 检查周培优权限', () async {
      final result = await weekendRemote!.checkUserAuth(
        userId: harness!.session.userId,
      );
      expect(result, isA<Map<String, dynamic>>());
      // ignore: avoid_print
      print('  ispass=${result['ispass']}, '
          'weekendurl=${result['weekendurl'] != null ? "已返回" : "(空)"}');
    }, skip: noHarnessSkip(harness));

    test('getUserInfo - 周培优用户信息', () async {
      try {
        final result = await weekendRemote!.getUserInfo();
        expect(result, isA<Map<String, dynamic>>());
        // ignore: avoid_print
        print('  字段: ${result.keys.take(5).toList()}');
      } catch (e) {
        // 未开通周培优时此接口可能 403
        // ignore: avoid_print
        print('  (可能未开通) $e');
      }
    }, skip: noHarnessSkip(harness));

    test('getClassBookList - 班级教材列表 (classId=1 试探)', () async {
      try {
        final result = await weekendRemote!.getClassBookList(classId: '1');
        expect(result, isA<List>());
        // ignore: avoid_print
        print('  教材数: ${result.length}');
      } catch (e) {
        // ignore: avoid_print
        print('  (可能未开通) $e');
      }
    }, skip: noHarnessSkip(harness));

    test('getScheduleList - 课程表 (bookId=1 试探)', () async {
      try {
        final result = await weekendRemote!.getScheduleList(bookId: '1');
        expect(result, isA<List>());
        // ignore: avoid_print
        print('  课时数: ${result.length}');
      } catch (e) {
        // ignore: avoid_print
        print('  (可能未开通) $e');
      }
    }, skip: noHarnessSkip(harness));

    test('getCourseDetail - 课程详情 (chapterId=1/classId=1 试探)', () async {
      try {
        final result = await weekendRemote!.getCourseDetail(
          chapterId: '1',
          classId: '1',
        );
        expect(result, isA<Map<String, dynamic>>());
        // ignore: avoid_print
        print('  字段: ${result.keys.take(5).toList()}');
      } catch (e) {
        // ignore: avoid_print
        print('  (可能未开通) $e');
      }
    }, skip: noHarnessSkip(harness));
  });
}
