/// 手写模拟配置 Riverpod Provider，负责配置的加载、保存与重置，并持久化到 shared_preferences。
/// 配置页与"手写模拟"开关均以此为默认值来源。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/handwriting_config.dart';

/// 手写模拟配置持久化键
const String _kHandwritingConfigKey = 'ewt_handwriting_config_v1';

/// 手写模拟配置持久化 Notifier
///
/// 与 [handwriting_config_page] 配合实现"配置可持久化":
/// - 打开配置页时读取已保存配置作为默认 (无则使用 [HandwritingConfig] 默认)
/// - 保存时写入 shared_preferences, 下次启动/再次打开仍生效
/// - 启用"手写模拟"开关时 (GenerateOptionsPanel) 也以它为默认值
class HandwritingConfigNotifier extends StateNotifier<HandwritingConfig> {
  HandwritingConfigNotifier() : super(const HandwritingConfig()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHandwritingConfigKey);
      if (raw == null || raw.isEmpty) return;
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        state = HandwritingConfig.fromJson(json);
      }
    } catch (_) {
      // 解析失败: 保持默认配置
    }
  }

  /// 保存配置并持久化
  Future<void> save(HandwritingConfig config) async {
    state = config;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHandwritingConfigKey, jsonEncode(config.toJson()));
    } catch (_) {
      // 持久化失败不影响本次内存状态
    }
  }

  /// 恢复默认并清除持久化
  Future<void> reset() async {
    state = const HandwritingConfig();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kHandwritingConfigKey);
    } catch (_) {
      // 忽略
    }
  }
}

/// 手写模拟配置 (已持久化) Provider
final handwritingConfigProvider =
    StateNotifierProvider<HandwritingConfigNotifier, HandwritingConfig>(
  (ref) => HandwritingConfigNotifier(),
);
