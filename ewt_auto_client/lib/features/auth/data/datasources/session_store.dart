/// 登录会话本地持久化（SharedPreferences），负责当前活跃会话的存取与清理。
/// 读取失败时自动清理脏数据并返回 null，上层 provider 只依赖本类接口。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/user_session.dart';

/// 登录会话本地持久化 (SharedPreferences)
///
/// 从 auth_provider (UI 层) 下沉的数据层组件: 负责会话的存取与清理,
/// provider 只依赖本类接口, 不直接操作 SharedPreferences。
class SessionStore {
  static const _sessionKey = 'active_session';

  const SessionStore();

  /// 持久化会话
  Future<void> save(UserSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
  }

  /// 清除已保存的会话
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
  }

  /// 读取上次保存的会话; 无会话或解析失败返回 null
  Future<UserSession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return UserSession.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      // 数据损坏时清理脏数据, 避免下次启动再次解析失败
      await clear();
      return null;
    }
  }
}
