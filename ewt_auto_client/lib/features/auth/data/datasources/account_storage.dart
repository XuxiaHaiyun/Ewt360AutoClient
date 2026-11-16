/// 账号持久化存储，用 shared_preferences 保存已登录账号列表（shared_preferences 内部维护）。
/// 以账号为唯一标识去重：同账号换 token 重新登录只原地更新，新会话缺失字段从旧条目合并。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';

/// 账号持久化存储
///
/// 使用 shared_preferences 保存已登录账号列表。
/// 列表以账号为唯一标识去重 (userId / account 命中即视为同一账号):
/// 同一账号换 token 重新登录只会原地更新原条目, 不会新增记录。
class AccountStorage {
  static const String _key = 'saved_accounts';

  /// 加载所有已保存账号
  static Future<List<UserSession>> loadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => UserSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存账号列表（覆盖）
  static Future<void> saveAccounts(List<UserSession> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(accounts.map((a) => a.toJson()).toList());
    await prefs.setString(_key, raw);
  }

  /// 添加或更新账号（以账号为唯一标识，而非 token）
  ///
  /// 命中同账号旧条目时原地替换（保留原位置），新会话缺失的字段
  /// （登录方式/记住的密码/代理等）从旧条目合并；其余同账号重复
  /// 条目一并清除。
  static Future<List<UserSession>> upsertAccount(UserSession session) async {
    final updated = upsertInList(await loadAccounts(), session);
    await saveAccounts(updated);
    return updated;
  }

  /// 在内存列表中插入或替换账号（纯函数, 不落盘）
  ///
  /// 以 [session] 为主合并所有同账号旧条目 (新会话字段始终优先), 替换首个
  /// 命中位置并清除其余同账号重复条目; 无命中时追加。
  static List<UserSession> upsertInList(
    List<UserSession> accounts,
    UserSession session,
  ) {
    var merged = session;
    var hitIdx = -1;
    for (var i = 0; i < accounts.length; i++) {
      final a = accounts[i];
      if (a.token == session.token || a.isSameAccount(session)) {
        merged = UserSession.merge(merged, a);
        if (hitIdx < 0) hitIdx = i;
      }
    }
    if (hitIdx < 0) return [...accounts, session];

    final result = <UserSession>[];
    for (var i = 0; i < accounts.length; i++) {
      final a = accounts[i];
      final isDup = a.token == session.token || a.isSameAccount(session);
      if (i == hitIdx) {
        result.add(merged);
      } else if (!isDup) {
        result.add(a);
      }
    }
    return result;
  }

  /// 按账号去重（纯函数）
  ///
  /// 同账号多条记录合并为一条, 保留首次出现的位置; 靠后的（较新）记录
  /// 为主, 靠前的补充缺失字段。仅 token 相同的记录同样视为重复。
  static List<UserSession> dedupeAccounts(List<UserSession> accounts) {
    final result = <UserSession>[];
    for (final a in accounts) {
      final idx =
          result.indexWhere((r) => r.token == a.token || r.isSameAccount(a));
      if (idx < 0) {
        result.add(a);
      } else {
        result[idx] = UserSession.merge(a, result[idx]);
      }
    }
    return result;
  }

  /// 更新账号代理并持久化 (设置页"当前登录账号代理"写入)
  ///
  /// 与 [session] token 相同或为同一账号 (userId / account 命中) 的存储
  /// 条目被更新; 未找到返回 null, 代理无变化返回原列表。
  /// [proxy] 为 `host:port` 格式, null/空串表示清除代理 (直连)。
  static Future<List<UserSession>?> setAccountProxy(
    UserSession session,
    String? proxy,
  ) async {
    final clean = (proxy == null || proxy.trim().isEmpty) ? null : proxy.trim();
    final accounts = await loadAccounts();
    final idx = accounts
        .indexWhere((a) => a.token == session.token || a.isSameAccount(session));
    if (idx < 0) return null;
    if (accounts[idx].proxy == clean) return accounts;
    final updated = List.of(accounts)..[idx] = accounts[idx].withProxy(clean);
    await saveAccounts(updated);
    return updated;
  }

  /// 删除账号
  static Future<List<UserSession>> removeAccounts(List<String> tokens) async {
    final accounts = await loadAccounts();
    accounts.removeWhere((a) => tokens.contains(a.token));
    await saveAccounts(accounts);
    return accounts;
  }
}
