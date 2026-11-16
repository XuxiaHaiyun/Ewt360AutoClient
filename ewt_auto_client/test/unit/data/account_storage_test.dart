/// AccountStorage 账号持久化去重单元测试 (SharedPreferences mock)
///
/// 覆盖: upsert 以账号为唯一标识 (换 token 原地替换) / 同账号多条历史
/// 记录合并 / 字段合并保留 (登录方式/密码/代理) / 持久化往返。
library;

import 'package:ewt_auto_client/features/auth/data/datasources/account_storage.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const stu1Old = UserSession(
    token: '10001-pc-tok-old',
    userId: '10001',
    schoolId: '10000',
    account: 'stu001',
    displayName: '小明',
    loginMethod: 'password',
    password: 'secret',
    proxy: '127.0.0.1:8080',
  );

  const stu2 = UserSession(
    token: '10002-pc-tok',
    userId: '10002',
    schoolId: '10000',
    account: 'stu002',
    displayName: '小红',
  );

  group('upsertAccount 以账号为唯一标识', () {
    test('同 userId 换新 token: 原地替换, 不新增条目', () async {
      await AccountStorage.saveAccounts([stu1Old, stu2]);

      final newer = stu1Old.copyWith(
        token: '10001-pc-tok-new',
        loginMethod: null,
        password: null,
      );
      final updated = await AccountStorage.upsertAccount(newer);

      expect(updated, hasLength(2), reason: '同账号不新增条目');
      expect(updated[0].token, '10001-pc-tok-new', reason: '原位置原地替换');
      expect(updated[1].token, '10002-pc-tok');
    });

    test('同 userId 换新 token: 新会话缺失的登录方式/密码/代理从旧条目合并', () async {
      await AccountStorage.saveAccounts([stu1Old]);

      final newer = const UserSession(
        token: '10001-pc-tok-new',
        userId: '10001',
        schoolId: '10000',
        account: 'stu001',
      );
      final updated = await AccountStorage.upsertAccount(newer);

      expect(updated.single.loginMethod, 'password');
      expect(updated.single.password, 'secret');
      expect(updated.single.proxy, '127.0.0.1:8080');
      expect(updated.single.displayName, '小明');
    });

    test('仅 account 相同 (userId 为空) 也视为同一账号', () async {
      final old = const UserSession(
        token: 'tok-old',
        userId: '',
        schoolId: '',
        account: 'stu001',
        loginMethod: 'sms',
      );
      await AccountStorage.saveAccounts([old]);

      final newer = const UserSession(
        token: 'tok-new',
        userId: '',
        schoolId: '',
        account: 'stu001',
      );
      final updated = await AccountStorage.upsertAccount(newer);

      expect(updated, hasLength(1));
      expect(updated.single.token, 'tok-new');
      expect(updated.single.loginMethod, 'sms', reason: '登录方式保留');
    });

    test('新账号正常追加', () async {
      await AccountStorage.saveAccounts([stu1Old]);

      final updated = await AccountStorage.upsertAccount(stu2);

      expect(updated, hasLength(2));
      expect(updated.last.token, '10002-pc-tok');
    });

    test('同账号多条历史重复记录一并清除', () async {
      final dup1 = stu1Old.copyWith(token: '10001-pc-tok-dup1');
      final dup2 = stu1Old.copyWith(token: '10001-pc-tok-dup2');
      await AccountStorage.saveAccounts([dup1, stu2, dup2, stu1Old]);

      final newer = stu1Old.copyWith(token: '10001-pc-tok-new');
      final updated = await AccountStorage.upsertAccount(newer);

      expect(updated, hasLength(2));
      expect(updated.where((a) => a.userId == '10001'), hasLength(1));
      expect(
        updated.firstWhere((a) => a.userId == '10001').token,
        '10001-pc-tok-new',
      );
    });
  });

  group('dedupeAccounts', () {
    test('同账号多条合并为一条, 靠后记录为主, 靠前补充缺失字段', () {
      // 靠前: 有登录方式/密码, 无昵称
      const first = UserSession(
        token: '10001-pc-tok-a',
        userId: '10001',
        schoolId: '10000',
        account: 'stu001',
        loginMethod: 'password',
        password: 'secret',
      );
      // 靠后 (较新): 有昵称, 无登录方式/密码
      const second = UserSession(
        token: '10001-pc-tok-b',
        userId: '10001',
        schoolId: '10000',
        account: 'stu001',
        displayName: '小明',
      );

      final deduped = AccountStorage.dedupeAccounts([first, second, stu2]);

      expect(deduped, hasLength(2));
      expect(deduped[0].token, '10001-pc-tok-b', reason: '靠后 (较新) 记录为主');
      expect(deduped[0].loginMethod, 'password', reason: '缺失字段从前一条补充');
      expect(deduped[0].password, 'secret');
      expect(deduped[0].displayName, '小明');
      expect(deduped[1].token, '10002-pc-tok');
    });

    test('仅 token 相同的记录同样视为重复', () {
      final a = stu1Old.copyWith(userId: '10001');
      final b = stu1Old.copyWith(userId: '10002');

      final deduped = AccountStorage.dedupeAccounts([a, b]);

      expect(deduped, hasLength(1));
      expect(deduped.single.userId, '10002');
    });

    test('不同账号互不影响, 顺序保持', () {
      final deduped = AccountStorage.dedupeAccounts([stu1Old, stu2, stu1Old]);

      expect(deduped, hasLength(2));
      expect(deduped[0].userId, '10001');
      expect(deduped[1].userId, '10002');
    });

    test('空列表返回空列表', () {
      expect(AccountStorage.dedupeAccounts(const []), isEmpty);
    });
  });

  group('setAccountProxy (设置页当前登录账号代理)', () {
    test('按 token 命中更新并落盘', () async {
      await AccountStorage.saveAccounts([stu1Old, stu2]);

      final updated = await AccountStorage.setAccountProxy(
        stu1Old,
        '10.0.0.1:3128',
      );

      expect(updated, isNotNull);
      expect(updated![0].proxy, '10.0.0.1:3128');
      expect(updated[1].proxy, isNull, reason: '不影响其他账号');
      expect((await AccountStorage.loadAccounts())[0].proxy, '10.0.0.1:3128');
    });

    test('按账号身份命中 (token 不同但同 userId)', () async {
      await AccountStorage.saveAccounts([stu1Old]);
      final refreshed = stu1Old.copyWith(token: '10001-pc-tok-new', proxy: null);

      final updated = await AccountStorage.setAccountProxy(
        refreshed,
        '10.0.0.1:3128',
      );

      expect(updated![0].token, '10001-pc-tok-old', reason: '更新的是存储条目');
      expect(updated[0].proxy, '10.0.0.1:3128');
    });

    test('清除代理 (null 归一为 null, 真正置空)', () async {
      await AccountStorage.saveAccounts([stu1Old]);

      final updated = await AccountStorage.setAccountProxy(stu1Old, null);

      expect(updated![0].proxy, isNull);
      expect((await AccountStorage.loadAccounts())[0].proxy, isNull);
    });

    test('账号不在列表时返回 null', () async {
      expect(
        await AccountStorage.setAccountProxy(stu1Old, '10.0.0.1:3128'),
        isNull,
      );
    });

    test('代理无变化时不落盘直接返回原列表', () async {
      await AccountStorage.saveAccounts([stu1Old]);

      final updated = await AccountStorage.setAccountProxy(
        stu1Old,
        stu1Old.proxy,
      );

      expect(updated, isNotNull);
      expect(updated, hasLength(1));
    });
  });

  group('loadAccounts 持久化往返', () {
    test('upsert 结果落盘后重新加载一致', () async {
      await AccountStorage.upsertAccount(stu1Old);
      await AccountStorage.upsertAccount(stu1Old.copyWith(token: 'tok-new'));

      final loaded = await AccountStorage.loadAccounts();
      expect(loaded, hasLength(1));
      expect(loaded.single.token, 'tok-new');
      expect(loaded.single.password, 'secret');
    });

    test('存储内容损坏时返回空列表', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_accounts', '{broken json');
      expect(await AccountStorage.loadAccounts(), isEmpty);
    });

    test('未存储时返回空列表', () async {
      expect(await AccountStorage.loadAccounts(), isEmpty);
    });
  });
}
