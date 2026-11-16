/// 风控配置模型: 解析远程配置 (总开关/启动密码/过期时间/功能开关矩阵),
/// 提供 isFeatureEnabled('group.item') 等判定; 未配置项均有默认兜底值。
library;

import 'package:intl/intl.dart';

/// 风控配置模型
class RiskControlConfig {
  final int schemaVersion;
  final bool enabled;
  final String startupPassword;
  final String startupPasswordPrompt;
  final String startupPasswordError;
  final DateTime? expireAt;
  final String disabledMessage;
  final String expiredMessage;

  /// features[group][item] = 开关
  final Map<String, Map<String, bool>> features;

  const RiskControlConfig({
    this.schemaVersion = 1,
    this.enabled = true,
    this.startupPassword = '',
    this.startupPasswordPrompt = '请输入启动密码',
    this.startupPasswordError = '启动密码错误，请重试',
    this.expireAt,
    this.disabledMessage = '软件已停用，请联系管理员。',
    this.expiredMessage = '软件授权已过期，请联系管理员续期。',
    this.features = const {},
  });

  factory RiskControlConfig.fromJson(Map<String, dynamic> json) {
    final app = (json['app'] as Map<String, dynamic>?) ?? {};
    final featsRaw = (json['features'] as Map<String, dynamic>?) ?? {};

    final features = <String, Map<String, bool>>{};
    featsRaw.forEach((group, value) {
      if (value is Map) {
        features[group] =
            value.map((k, v) => MapEntry(k.toString(), v == true));
      }
    });

    DateTime? expire;
    final expStr = app['expire_at']?.toString();
    if (expStr != null && expStr.isNotEmpty) {
      try {
        expire = DateFormat('yyyy-MM-dd HH:mm:ss').parse(expStr);
      } catch (_) {
        expire = null;
      }
    }

    return RiskControlConfig(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
      enabled: app['enabled'] != false,
      startupPassword: app['startup_password']?.toString() ?? '',
      startupPasswordPrompt:
          app['startup_password_prompt']?.toString() ?? '请输入启动密码',
      startupPasswordError:
          app['startup_password_error']?.toString() ?? '启动密码错误，请重试',
      expireAt: expire,
      disabledMessage:
          app['disabled_message']?.toString() ?? '软件已停用，请联系管理员。',
      expiredMessage:
          app['expired_message']?.toString() ?? '软件授权已过期，请联系管理员续期。',
      features: features,
    );
  }

  /// 默认配置 (开发兜底, 全部启用)
  factory RiskControlConfig.defaults() => const RiskControlConfig(
        expireAt: null,
        features: {},
      );

  bool isAppEnabled() => enabled;

  bool isExpired() =>
      expireAt != null && DateTime.now().isAfter(expireAt!);

  bool get hasStartupPassword => startupPassword.isNotEmpty;

  bool verifyStartupPassword(String input) =>
      hasStartupPassword && input == startupPassword;

  /// 形如 'homework_menu.report' -> group=item
  ///
  /// 仅受 [enabled] 与 features 开关影响, 不受 [isExpired] 影响
  /// (过期由 main.dart 弹窗后直接退出, 不会进入功能页)。
  bool isFeatureEnabled(String dottedKey) {
    if (!isAppEnabled()) return false;
    final dot = dottedKey.indexOf('.');
    if (dot < 0) return false;
    final group = dottedKey.substring(0, dot);
    final item = dottedKey.substring(dot + 1);
    return features[group]?[item] == true;
  }
}
