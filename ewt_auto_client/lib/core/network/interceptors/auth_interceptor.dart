/// 认证拦截器: 为每个请求注入 token (未登录为 '0') 及端点静态头
/// (UA/Origin/Referer/设备信息), 对应 Python base.py 的动态头构建。
library;

import 'package:dio/dio.dart';

import '../../config/endpoint_config.dart';

/// 认证拦截器
///
/// 注入 token 和端点相关的静态 headers (UA, Origin, Referer, 设备信息等)
/// 对应 Python: core/base.py _build_dynamic_headers + _load_endpoint_config
class AuthInterceptor extends Interceptor {
  final EndpointConfig _endpointConfig;

  /// 当前会话 token，登录后设置
  String? token;

  AuthInterceptor(this._endpointConfig);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Token
    options.headers['token'] = token ?? '0';

    // 端点相关 headers
    final config = _endpointConfig;
    options.headers['User-Agent'] = config.userAgent;
    options.headers['Origin'] = config.origin;
    options.headers['Referer'] = config.referer;

    // 额外 headers (sec-ch-ua 等 / APP 设备 headers)
    for (final entry in config.extraHeaders.entries) {
      options.headers[entry.key] = entry.value;
    }

    handler.next(options);
  }
}
