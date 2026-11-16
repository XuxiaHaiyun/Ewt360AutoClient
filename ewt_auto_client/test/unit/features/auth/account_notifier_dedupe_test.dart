/// AccountNotifier 账号列表去重单元测试 (SharedPreferences mock)
///
/// 覆盖: 登录成功保存账号时按账号去重 (换 token 不重复) / 加载历史
/// 重复数据时合并去重并回写存储。
library;

import 'dart:convert';

import 'package:ewt_auto_client/features/auth/data/datasources/account_storage.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:ewt_auto_client/features/auth/presentation/providers/account_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const stu1 = UserSession(
    token: '10001-pc-tok-1',
    userId: '10001',
    schoolId: '10000',
    account: 'stu001',
    displayName: '小明',
    loginMethod: 'password',
    password: 'secret',
  );

  test('addAccount: 同账号换新 token 不产生重复条目', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpEventQueue(); // 等待构造时 _load 完成

    final notifier = container.read(accountProvider.notifier);
    await notifier.addAccount(stu1);
    await notifier.addAccount(stu1.copyWith(token: '10001-pc-tok-2'));

    final accounts = container.read(accountProvider).accounts;
    expect(accounts, hasLength(1));
    expect(accounts.single.token, '10001-pc-tok-2');
    expect(accounts.single.password, 'secret', reason: '记住的密码保留');
  });

  test('addAccount: 换 token 后旧 token 从存储中移除', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpEventQueue();

    final notifier = container.read(accountProvider.notifier);
    await notifier.addAccount(stu1);
    await notifier.addAccount(stu1.copyWith(token: '10001-pc-tok-2'));

    final saved = jsonDecode(prefs.getString('saved_accounts')!) as List;
    expect(saved, hasLength(1));
    expect((saved.single as Map)['token'], '10001-pc-tok-2');
  });

  test('加载时对历史同账号重复数据合并去重并回写存储', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'saved_accounts',
      jsonEncode([
        stu1.toJson(),
        stu1.copyWith(token: '10001-pc-tok-2').toJson(),
      ]),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 触发 notifier 创建 (_load 异步执行)
    container.read(accountProvider.notifier);
    await pumpEventQueue();

    expect(container.read(accountProvider).accounts, hasLength(1));
    // 去重结果已回写存储
    final saved = jsonDecode(prefs.getString('saved_accounts')!) as List;
    expect(saved, hasLength(1));
  });

  test('正常多账号列表加载不受去重影响', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpEventQueue();

    final notifier = container.read(accountProvider.notifier);
    await notifier.addAccount(stu1);
    await notifier.addAccount(stu1.copyWith(
      token: '10002-pc-tok',
      userId: '10002',
      account: 'stu002',
    ));

    expect(container.read(accountProvider).accounts, hasLength(2));
  });

  test('updateAccountProxy 清除代理真正置空 (回归: copyWith null 保留原值)', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpEventQueue();

    final notifier = container.read(accountProvider.notifier);
    await notifier.addAccount(stu1);

    // 设置
    await notifier.updateAccountProxy('10001-pc-tok-1', '10.0.0.1:3128');
    expect(
      container.read(accountProvider).accounts.single.proxy,
      '10.0.0.1:3128',
    );

    // 清除: 旧实现 copyWith(proxy: null) 会保留旧值, 清除无效
    await notifier.updateAccountProxy('10001-pc-tok-1', null);
    expect(container.read(accountProvider).accounts.single.proxy, isNull);
    expect(
      (await AccountStorage.loadAccounts()).single.proxy,
      isNull,
      reason: '存储同步清除',
    );
  });

  test('updateAccountProxy 以存储为准 (状态未加载也能写入)', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_accounts', jsonEncode([stu1.toJson()]));

    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 不等待 _load 完成即写入 (存储层数据为准)
    final notifier = container.read(accountProvider.notifier);
    await notifier.updateAccountProxy('10001-pc-tok-1', '10.0.0.1:3128');

    expect((await AccountStorage.loadAccounts()).single.proxy, '10.0.0.1:3128');
  });

  test('reload 重新加载外部改写的存储', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpEventQueue();

    final notifier = container.read(accountProvider.notifier);
    await notifier.addAccount(stu1);

    // 外部 (设置页路径) 直接改写存储
    await AccountStorage.setAccountProxy(stu1, '10.0.0.1:3128');
    expect(container.read(accountProvider).accounts.single.proxy, isNull,
        reason: '状态尚未刷新');

    await notifier.reload();
    expect(
      container.read(accountProvider).accounts.single.proxy,
      '10.0.0.1:3128',
    );
  });
}
