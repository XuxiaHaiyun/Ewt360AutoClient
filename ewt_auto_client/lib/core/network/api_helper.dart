/// 网络层公共工具: 站点级 Origin/Referer 请求头 (ApiHeaders, 供非网关直连请求)、
/// 字段安全解析 (int/String/bool) 与业务响应校验模板 (ensureData/ensureSuccess/ensureList)。
library;

import 'dio_client.dart';

/// 常见 EWT 站点级请求头 (Origin/Referer)
///
/// 网关拦截器 ([auth_interceptor]) 会为走 [DioClient] 的请求自动附加
/// EndpointConfig 中配置的 Origin/Referer; 这里供**非网关请求** (直连
/// OSS/VOD/验证码等独立域名) 使用。
abstract final class ApiHeaders {
  ApiHeaders._();

  static const Map<String, String> web = {
    'Origin': 'https://web.ewt360.com',
    'Referer': 'https://web.ewt360.com/',
  };

  static const Map<String, String> teacher = {
    'Origin': 'https://teacher.ewt360.com',
    'Referer': 'https://teacher.ewt360.com/',
  };

  static const Map<String, String> www = {
    'Origin': 'https://www.ewt360.com',
    'Referer': 'https://www.ewt360.com/',
  };
}

/// 网络层公共工具: 统一请求头 / 字段解析 / 业务错误模板
///
/// 收敛各 datasource/service 中重复的 Origin/Referer 头、`_parseInt` 解析、
/// `!isSuccess → throw NetworkException` 判断, 保证网络层风格一致、可维护。
abstract final class ApiHelper {
  ApiHelper._();

  // ─── 字段解析工具 ───

  /// 安全解析 int 字段 (支持 int / double / 数字字符串 / null)
  static int? parseIntOrNull(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String && value.trim().isNotEmpty) {
      final s = value.trim();
      final i = int.tryParse(s);
      if (i != null) return i;
      // 支持小数数字字符串 ("12.9" → 12), API 进度类字段常见
      final d = double.tryParse(s);
      if (d != null) return d.toInt();
      return null;
    }
    return null;
  }

  /// 安全解析 int 字段, 失败回退 [fallback]
  static int parseInt(dynamic value, [int fallback = 0]) =>
      parseIntOrNull(value) ?? fallback;

  /// 安全解析 String 字段, 非 null 值一律 toString
  static String parseString(dynamic value, [String fallback = '']) =>
      value?.toString() ?? fallback;

  /// 安全解析 bool 字段 (支持 bool / 0/1 / 'true'/'false' 字符串)
  static bool parseBool(dynamic value, [bool fallback = false]) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final s = value.trim().toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes') return true;
      if (s == 'false' || s == '0' || s == 'no') return false;
    }
    return fallback;
  }

  // ─── 业务响应校验 ───

  /// 校验业务响应: 失败时抛出 [NetworkException], 成功返回 data
  ///
  /// 统一各 datasource 中 `if (!response.isSuccess) throw ...` 模板。
  /// [data] 为 null 时返回 [fallback] (默认空 Map), 避免调用方重复判空。
  static Map<String, dynamic> ensureData(
    ApiResponse<dynamic> response,
    String errorPrefix, {
    Map<String, dynamic> fallback = const {},
  }) {
    if (!response.isSuccess) {
      throw NetworkException('$errorPrefix: ${response.msg}');
    }
    final data = response.data;
    return data is Map<String, dynamic> ? data : fallback;
  }

  /// 校验业务响应并返回原始 data (可能为 null / 非 Map, 如纯字符串 token)
  static dynamic ensureSuccess(
    ApiResponse<dynamic> response,
    String errorPrefix,
  ) {
    if (!response.isSuccess) {
      throw NetworkException('$errorPrefix: ${response.msg}');
    }
    return response.data;
  }

  /// 校验业务响应, 返回 data 是否为 List<Map>
  static List<Map<String, dynamic>> ensureList(
    ApiResponse<dynamic> response,
    String errorPrefix, {
    List<Map<String, dynamic>> fallback = const [],
  }) {
    if (!response.isSuccess) {
      throw NetworkException('$errorPrefix: ${response.msg}');
    }
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return fallback;
  }
}
