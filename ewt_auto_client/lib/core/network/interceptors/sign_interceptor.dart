/// 请求签名拦截器: 为每个请求注入 timestamp + sign (MD5(ts+secretKey))
/// + secretId + platform 头, 对应 Python base.py 的签名逻辑。
library;

import 'package:dio/dio.dart';

import '../../config/endpoint_config.dart';
import '../../crypto/crypto_utils.dart';

/// 请求签名拦截器
///
/// 为每个请求注入 timestamp + sign + secretId + platform 头
/// 对应 Python: core/base.py _build_dynamic_headers 中的签名逻辑
class SignInterceptor extends Interceptor {
  final EndpointConfig _endpointConfig;

  SignInterceptor(this._endpointConfig);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final timestamp = RequestSigner.generateTimestamp();
    final sign = RequestSigner.generateSign(
      timestamp,
      _endpointConfig.secretKey,
    );

    options.headers['timestamp'] = '$timestamp';
    options.headers['sign'] = sign;
    options.headers['secretId'] = _endpointConfig.secretId;
    options.headers['platform'] = _endpointConfig.platform;

    handler.next(options);
  }
}
