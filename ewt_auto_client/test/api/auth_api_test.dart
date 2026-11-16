// 认证 API 集成测试 (真实网关, 需 test/accounts.json)
//
// 复用 [AuthRemoteDataSource] 验证 token/用户信息/学校信息接口的连通性。
// 不做任何 mock, 调用真实 EWT360 网关。
// 无有效账号时整个文件自动 skip。
import 'package:ewt_auto_client/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  AuthRemoteDataSource? authRemote;

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    authRemote = h == null ? null : AuthRemoteDataSource(h.client);
  });
  tearDownAll(() => harness?.dispose());

  group('认证 API', () {
    test('validateToken - 获取用户信息', () async {
      final userInfo = await authRemote!.validateToken(harness!.session.token);
      expect(userInfo, isA<Map<String, dynamic>>());
      expect(userInfo['userId']?.toString(), isNotEmpty);
      // ignore: avoid_print
      print('  userId=${userInfo['userId']}, '
          'userName=${userInfo['userName'] ?? userInfo['account']}');
    }, skip: noHarnessSkip(harness));

    test('getBaseInfo - 获取基本信息', () async {
      final baseInfo = await authRemote!.getBaseInfo();
      expect(baseInfo, isA<Map<String, dynamic>>());
      expect(baseInfo['userId']?.toString(), isNotEmpty);
      // ignore: avoid_print
      print('  baseInfo.userId=${baseInfo['userId']}, '
          'mobile=${baseInfo['mobile']}');
    }, skip: noHarnessSkip(harness));

    test('getSchoolUserInfo - 获取学校用户信息', () async {
      final schoolUserInfo = await authRemote!.getSchoolUserInfo();
      expect(schoolUserInfo, isA<Map<String, dynamic>>());
      // 打印 schoolId 用于校验
      // ignore: avoid_print
      print('  schoolUserInfo.schoolId=${schoolUserInfo['schoolId']}, '
          'schoolName=${schoolUserInfo['schoolName']}');
    }, skip: noHarnessSkip(harness));
  });
}
