/// 启动密码本地缓存: 仅存上次验证通过密码的 SHA-256 哈希 (不含明文),
/// 远程密码未变更时跳过弹窗, 变更/首次/清空时相应弹窗或清除。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动密码本地缓存
///
/// 仅缓存"上次成功验证通过"的密码哈希, 避免远程密码未变更时反复弹窗。
///
/// 规则:
///   - 远程密码哈希 == 本地缓存哈希 → 跳过弹窗 (密码未变)
///   - 远程密码哈希 != 本地缓存哈希 → 弹窗输入 (密码已变或首次)
///   - 验证通过后 → 更新本地缓存为当前远程密码哈希
///   - 验证取消/失败 → 不更新缓存, 下次仍需输入
///
/// 仅存储 SHA-256 哈希, 不存储明文密码。
class RiskControlPasswordCache {
  RiskControlPasswordCache._();

  static const String _key = 'rc_startup_password_hash';

  /// 计算密码的 SHA-256 哈希 (hex)
  static String hashPassword(String password) {
    return sha256.convert(utf8.encode(password)).toString();
  }

  /// 读取本地缓存的密码哈希, 无缓存返回 null
  static Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  /// 写入密码哈希到本地缓存
  static Future<void> write(String hash) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, hash);
  }

  /// 判断远程密码是否与本地缓存一致 (一致则跳过弹窗)
  static Future<bool> isUnchanged(String remotePassword) async {
    final cached = await read();
    if (cached == null) return false;
    return cached == hashPassword(remotePassword);
  }

  /// 验证通过后更新缓存为当前远程密码哈希
  static Future<void> markVerified(String remotePassword) async {
    await write(hashPassword(remotePassword));
  }

  /// 清除缓存 (密码被远程清空或停用时调用)
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
