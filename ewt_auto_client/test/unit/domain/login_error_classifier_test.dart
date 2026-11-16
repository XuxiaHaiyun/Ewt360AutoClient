/// 登录错误分类器单元测试 (离线, 自包含)
///
/// 覆盖 [LoginErrorClassifier]（对齐 web `ewtLogin` chunk 实测逻辑）:
///   - 需改密 failCode 集合: 017179(需改初始密码) / 017180(需设初始密码) / 017442(强制改密)
///   - 改密触发条件: 登录成功 + `data.failCode` 命中集合 + 非空 `checkToken`
///   - 失败类响应一律不算改密: 017133(密码错误) / 017126 / 017421(web 静默忽略) /
///     017129 / 017130(滑块) / 普通成功登录(无 failCode)
///   - [LoginErrorClassifier.extractCheckToken] 取值与 `token` 兜底
///   - [PasswordChangeRequiredException] 序列化
library;

import 'package:ewt_auto_client/features/auth/domain/auth_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('passwordChangeFailCodes', () {
    test('包含真实需改密 failCode (017179/017180/017442)', () {
      expect(LoginErrorClassifier.passwordChangeFailCodes, contains('017179'));
      expect(LoginErrorClassifier.passwordChangeFailCodes, contains('017180'));
      expect(LoginErrorClassifier.passwordChangeFailCodes, contains('017442'));
    });

    test('017126/017421 不属于改密集合 (web 失败处理中静默忽略)', () {
      expect(
        LoginErrorClassifier.passwordChangeFailCodes,
        isNot(contains('017126')),
      );
      expect(
        LoginErrorClassifier.passwordChangeFailCodes,
        isNot(contains('017421')),
      );
    });

    test('滑块码/密码错误码不属于改密集合', () {
      expect(
        LoginErrorClassifier.passwordChangeFailCodes,
        isNot(contains('017129')),
      );
      expect(
        LoginErrorClassifier.passwordChangeFailCodes,
        isNot(contains('017130')),
      );
      expect(
        LoginErrorClassifier.passwordChangeFailCodes,
        isNot(contains('017133')),
      );
    });
  });

  group('isPasswordChangeRequired - 成功 + failCode + checkToken', () {
    test('failCode=017179 + checkToken → 需改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {
            'failCode': '017179',
            'checkToken': 'tok-abc',
            'upgradeJumpCode': 2,
            'token': null,
          },
        ),
        isTrue,
      );
    });

    test('failCode=017180 + checkToken → 需改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {'failCode': '017180', 'checkToken': 'tok-abc'},
        ),
        isTrue,
      );
    });

    test('failCode=017442 + checkToken → 需改密 (强制改密)', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {'failCode': '017442', 'checkToken': 'tok-abc'},
        ),
        isTrue,
      );
    });

    test('failCode 命中但缺 checkToken → 不改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {'failCode': '017179'},
        ),
        isFalse,
      );
    });

    test('failCode 命中但 checkToken 为空串 → 不改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {'failCode': '017179', 'checkToken': ''},
        ),
        isFalse,
      );
    });

    test('checkToken 命中但 failCode 不命中 → 不改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {'failCode': '017999', 'checkToken': 'tok-abc'},
        ),
        isFalse,
      );
    });
  });

  group('isPasswordChangeRequired - 普通成功登录不误判', () {
    test('成功登录仅有 token、无 failCode → 不改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '操作成功',
          isSuccess: true,
          data: {'token': 'session-token', 'userId': 10001},
        ),
        isFalse,
      );
    });

    test('成功登录带 status=2 但无 failCode → 不改密 (status 非判定字段)', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {'token': 't', 'status': 2},
        ),
        isFalse,
      );
    });

    test('成功登录带 upgradeJumpCode=2 但无 failCode → 不改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '200',
          msg: '',
          isSuccess: true,
          data: {'token': 't', 'upgradeJumpCode': 2},
        ),
        isFalse,
      );
    });
  });

  group('isPasswordChangeRequired - 失败类响应一律不改密', () {
    test('密码错误 017133 (data=null) → 不改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '017133',
          msg: '账号或密码错误',
          isSuccess: false,
        ),
        isFalse,
      );
    });

    test('017126 失败 (data=null) → 不改密 (web 静默忽略)', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '017126',
          msg: '',
          isSuccess: false,
        ),
        isFalse,
      );
    });

    test('017421 失败 (data=null) → 不改密 (web 静默忽略)', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '017421',
          msg: '',
          isSuccess: false,
        ),
        isFalse,
      );
    });

    test('失败但 data 携带 failCode=017179 + checkToken → 不改密 (仅成功才改密)', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '017133',
          msg: '账号或密码错误',
          isSuccess: false,
          data: {'failCode': '017179', 'checkToken': 'tok-abc'},
        ),
        isFalse,
      );
    });

    test('滑块 017129/017130 失败 → 不改密', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '017129',
          msg: '登录密码错误超限，请进行安全校验',
          isSuccess: false,
        ),
        isFalse,
      );
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '017130',
          msg: '',
          isSuccess: false,
        ),
        isFalse,
      );
    });

    test('失败文案含"修改密码/弱密码"字样 → 不改密 (文案不参与判定)', () {
      expect(
        LoginErrorClassifier.isPasswordChangeRequired(
          code: '017999',
          msg: '当前密码过于简单，为了账号安全，请修改密码',
          isSuccess: false,
        ),
        isFalse,
      );
    });
  });

  group('extractCheckToken', () {
    test('优先取 checkToken', () {
      expect(
        LoginErrorClassifier.extractCheckToken(
          {'checkToken': 't-check', 'token': 't-fallback'},
        ),
        't-check',
      );
    });

    test('checkToken 缺失时回退 token', () {
      expect(
        LoginErrorClassifier.extractCheckToken({'token': 't-fallback'}),
        't-fallback',
      );
    });

    test('data 为 null 返回 null', () {
      expect(LoginErrorClassifier.extractCheckToken(null), isNull);
    });

    test('均无相关字段返回 null', () {
      expect(LoginErrorClassifier.extractCheckToken({'status': 2}), isNull);
    });
  });

  group('PasswordChangeRequiredException', () {
    test('toString 返回 message', () {
      const ex = PasswordChangeRequiredException(
        account: 'u1',
        oldPassword: 'old',
        checkToken: 'tok',
        message: '当前密码过于简单，为了账号安全，请修改密码',
        failCode: '017179',
      );
      expect(ex.toString(), '当前密码过于简单，为了账号安全，请修改密码');
      expect(ex.account, 'u1');
      expect(ex.checkToken, 'tok');
      expect(ex.failCode, '017179');
    });

    test('checkToken 可为 null', () {
      const ex = PasswordChangeRequiredException(
        account: 'u2',
        oldPassword: 'old',
        message: '请修改密码',
      );
      expect(ex.checkToken, isNull);
      expect(ex.failCode, isNull);
    });
  });
}
