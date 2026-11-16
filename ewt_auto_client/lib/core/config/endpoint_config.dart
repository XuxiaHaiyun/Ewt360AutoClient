/// WEB 端点配置: 固定 secretId=2 / platform=1, 管理 UA、SDK 版本与
/// 额外请求头, 可从 web_device_info.json 加载或使用默认 Edge/Chrome 指纹。
library;

import '../constants/crypto_constants.dart';

/// WEB 端点配置
///
/// 固定使用 WEB 端点 (secretId=2, platform=1)
class EndpointConfig {
  String _userAgent;
  String _sdkVersion;
  Map<String, String> _extraHeaders;

  EndpointConfig._({
    required String userAgent,
    required String sdkVersion,
    required Map<String, String> extraHeaders,
  })  : _userAgent = userAgent,
        _sdkVersion = sdkVersion,
        _extraHeaders = extraHeaders;

  /// 从 web_device_info.json 加载
  factory EndpointConfig.fromJson(Map<String, dynamic> json) {
    // 防御性转换: json['api']/json['headers'] 可能是 Map<dynamic, dynamic>
    // (如字面量 {} 或混合类型 map), 直接 `as Map<String, dynamic>` 会抛
    // type cast 异常
    Map<String, dynamic> asStrMap(dynamic value) =>
        value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{};
    final api = asStrMap(json['api']);
    final headers = asStrMap(json['headers']);

    return EndpointConfig._(
      userAgent: api['user_agent'] as String? ?? _defaultUA,
      sdkVersion: api['sdk_version'] as String? ?? '3.0.37',
      extraHeaders: headers.map((k, v) => MapEntry(k, v.toString())),
    );
  }

  /// 默认配置
  factory EndpointConfig.defaults() {
    return EndpointConfig._(
      userAgent: _defaultUA,
      sdkVersion: '3.0.37',
      extraHeaders: {
        'sec-ch-ua':
            '"Not(A:Brand";v="8", "Chromium";v="147", "Microsoft Edge";v="147"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'Sec-Fetch-Site': 'same-site',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Dest': 'empty',
        'DNT': '1',
      },
    );
  }

  static const _defaultUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0';

  // ─── 固定 WEB 端点常量 ───
  String get secretId => CryptoConstants.webSecretId;
  String get secretKey => CryptoConstants.webSignSecretKey;
  String get platform => CryptoConstants.webPlatform;
  String get origin => 'https://www.ewt360.com';
  String get referer => 'https://www.ewt360.com/';

  /// 心跳间隔（秒）
  int get reportInterval => 60;

  // ─── 可变配置 ───
  String get userAgent => _userAgent;
  String get sdkVersion => _sdkVersion;
  Map<String, String> get extraHeaders => _extraHeaders;

  void update({
    String? userAgent,
    String? sdkVersion,
    Map<String, String>? extraHeaders,
  }) {
    if (userAgent != null) _userAgent = userAgent;
    if (sdkVersion != null) _sdkVersion = sdkVersion;
    if (extraHeaders != null) _extraHeaders = extraHeaders;
  }
}
