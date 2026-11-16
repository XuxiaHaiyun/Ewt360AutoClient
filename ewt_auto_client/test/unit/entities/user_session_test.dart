/// UserSession 实体单元测试 (离线)
///
/// 覆盖 JSON 序列化往返 / copyWith / 默认容错。
library;

import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const session = UserSession(
    token: 'tok-1',
    userId: '10001',
    schoolId: '10000',
    account: 'stu001',
    displayName: '小明',
    avatar: 'https://x/a.png',
    schoolName: '测试中学',
    provinceCode: '44',
    mobile: '13800000000',
    proxy: '127.0.0.1:8080',
  );

  group('UserSession.toJson/fromJson', () {
    test('完整字段往返一致', () {
      final back = UserSession.fromJson(session.toJson());
      expect(back.token, 'tok-1');
      expect(back.userId, '10001');
      expect(back.schoolId, '10000');
      expect(back.account, 'stu001');
      expect(back.displayName, '小明');
      expect(back.avatar, 'https://x/a.png');
      expect(back.schoolName, '测试中学');
      expect(back.provinceCode, '44');
      expect(back.mobile, '13800000000');
      expect(back.proxy, '127.0.0.1:8080');
    });

    test('代理字段缺失时回退 null (直连)', () {
      final back = UserSession.fromJson({});
      expect(back.proxy, isNull);
    });

    test('缺失字段容错: token/userId/schoolId 回退空串, 其余为 null', () {
      final back = UserSession.fromJson({});
      expect(back.token, '');
      expect(back.userId, '');
      expect(back.schoolId, '');
      expect(back.account, isNull);
      expect(back.displayName, isNull);
    });

    test('数值型字段安全转换', () {
      final back = UserSession.fromJson({
        'token': 123,
        'userId': 456,
        'schoolId': 789,
      });
      expect(back.token, '123');
      expect(back.userId, '456');
      expect(back.schoolId, '789');
    });

    test('null 字段在 JSON 中保留为 null', () {
      final json = session.toJson();
      expect(json['account'], 'stu001');
      final empty = const UserSession(token: 't', userId: '', schoolId: '')
          .toJson();
      expect(empty['displayName'], isNull);
    });
  });

  group('UserSession.copyWith', () {
    test('不传字段保留原值', () {
      final copy = session.copyWith();
      expect(copy.token, session.token);
      expect(copy.displayName, session.displayName);
    });

    test('传字段覆盖', () {
      final copy = session.copyWith(token: 'tok-2', displayName: '小红');
      expect(copy.token, 'tok-2');
      expect(copy.displayName, '小红');
      expect(copy.userId, session.userId, reason: '未覆盖字段保留');
    });

    test('proxy 可单独更新', () {
      final copy = session.copyWith(proxy: '10.0.0.1:3128');
      expect(copy.proxy, '10.0.0.1:3128');
      expect(copy.token, session.token, reason: '未覆盖字段保留');
    });
  });

  group('UserSession.withProxy', () {
    test('设置代理', () {
      const base = UserSession(
        token: 'tok-1',
        userId: '10001',
        schoolId: '10000',
      );
      final withP = base.withProxy('10.0.0.1:3128');
      expect(withP.proxy, '10.0.0.1:3128');
      expect(withP.token, 'tok-1', reason: '其余字段保留');
    });

    test('清除代理 (null / 空串 / 空白均归一为 null)', () {
      const base = UserSession(
        token: 'tok-1',
        userId: '10001',
        schoolId: '10000',
        proxy: '10.0.0.1:3128',
      );
      expect(base.withProxy(null).proxy, isNull);
      expect(base.withProxy('').proxy, isNull);
      expect(base.withProxy('   ').proxy, isNull);
    });

    test('代理自动 trim, 其余字段原样保留', () {
      final trimmed = session.withProxy('  10.0.0.1:3128  ');
      expect(trimmed.proxy, '10.0.0.1:3128');
      expect(trimmed.displayName, session.displayName);
      expect(trimmed.password, session.password);
      expect(trimmed.loginMethod, session.loginMethod);
    });
  });

  group('UserSession.isSameAccount', () {
    test('userId 相同视为同一账号 (account 不同也算)', () {
      final a = session.copyWith(token: 'tok-1', account: 'stu001');
      final b = session.copyWith(token: 'tok-2', account: 'stu001-new');
      expect(a.isSameAccount(b), isTrue);
      expect(b.isSameAccount(a), isTrue);
    });

    test('userId 不同视为不同账号 (即使 account 相同)', () {
      final a = session.copyWith(token: 'tok-1', userId: '10001');
      final b = session.copyWith(token: 'tok-2', userId: '10002');
      expect(a.isSameAccount(b), isFalse);
    });

    test('userId 为空时回退 account 比对', () {
      final a = session.copyWith(token: 'tok-1', userId: '', account: 'stu');
      final b = session.copyWith(token: 'tok-2', userId: '', account: 'stu');
      expect(a.isSameAccount(b), isTrue);
    });

    test('userId 与 account 均无法判定时不视为同一账号', () {
      const a = UserSession(token: 'tok-1', userId: '', schoolId: '');
      const b = UserSession(token: 'tok-2', userId: '', schoolId: '');
      expect(a.isSameAccount(b), isFalse);
    });

    test('仅一方有 userId 时回退 account 比对', () {
      final a = session.copyWith(token: 'tok-1', userId: '10001');
      final b = session.copyWith(token: 'tok-2', userId: '', account: 'stu001');
      expect(a.isSameAccount(b), isTrue);
    });
  });

  group('UserSession.merge', () {
    test('以新会话为主, 旧会话补充缺失字段', () {
      final older = session.copyWith(token: 'tok-1');
      final newer = const UserSession(token: 'tok-2', userId: '10001', schoolId: '');
      final merged = UserSession.merge(newer, older);
      expect(merged.token, 'tok-2', reason: 'token 以新会话为准');
      expect(merged.schoolId, '10000', reason: '新会话缺失的字段从旧会话补充');
      expect(merged.displayName, '小明');
      expect(merged.proxy, '127.0.0.1:8080');
    });

    test('换 token 重新登录保留旧记录的登录方式/密码/代理', () {
      final older = session.copyWith(
        token: 'tok-1',
        loginMethod: 'password',
        password: 'secret',
      );
      final newer = session.copyWith(token: 'tok-2', password: null);
      final merged = UserSession.merge(newer, older);
      expect(merged.token, 'tok-2');
      expect(merged.loginMethod, 'password');
      expect(merged.password, 'secret');
      expect(merged.proxy, '127.0.0.1:8080');
    });

    test('新会话字段齐全时旧值不覆盖', () {
      final older = session.copyWith(token: 'tok-1', displayName: '旧名字');
      final newer = session.copyWith(token: 'tok-2', displayName: '新名字');
      final merged = UserSession.merge(newer, older);
      expect(merged.displayName, '新名字');
      expect(merged.token, 'tok-2');
    });

    test('新会话空串字段同样视为缺失', () {
      final older = session.copyWith(token: 'tok-1', mobile: '13800000000');
      final newer = session.copyWith(token: 'tok-2', mobile: '');
      final merged = UserSession.merge(newer, older);
      expect(merged.mobile, '13800000000');
    });
  });
}
