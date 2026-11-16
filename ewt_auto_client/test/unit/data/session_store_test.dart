/// SessionStore 会话持久化单元测试 (SharedPreferences mock)
library;

import 'package:ewt_auto_client/features/auth/data/datasources/session_store.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const store = SessionStore();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('save 后可 load 出相同会话', () async {
    const session = UserSession(
      token: 'tok-1',
      userId: '10001',
      schoolId: '40092',
      account: 'test',
      displayName: '测试用户',
    );
    await store.save(session);

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.token, 'tok-1');
    expect(loaded.userId, '10001');
    expect(loaded.schoolId, '40092');
    expect(loaded.displayName, '测试用户');
  });

  test('无会话时 load 返回 null', () async {
    expect(await store.load(), isNull);
  });

  test('clear 后 load 返回 null', () async {
    const session = UserSession(token: 't', userId: 'u', schoolId: 's');
    await store.save(session);
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('数据损坏时 load 返回 null 并清理脏数据', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_session', '{broken json');
    expect(await store.load(), isNull);
    // 脏数据已被清理
    expect(prefs.getString('active_session'), isNull);
  });

  test('数值型 userId 持久化后可安全加载', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'active_session',
      '{"token":"t","userId":10001,"schoolId":40092}',
    );
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.userId, '10001');
    expect(loaded.schoolId, '40092');
  });
}
