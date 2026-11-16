/// 连接类失败自动重试拦截器: 仅重试 connectionTimeout/connectionError
/// (请求未送达服务端, 无重复提交风险), 次数/间隔实时读 NetworkTuning。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import 'network_tuning.dart';

/// 连接失败自动重试拦截器
///
/// 仅对"连接未建立"类错误重试 ([DioExceptionType.connectionTimeout] /
/// [DioExceptionType.connectionError]): 此时请求尚未送达服务端, 任意
/// HTTP 方法重试均无重复提交风险; 响应类错误 (badResponse 等) 不重试。
///
/// 重试经 [_dio.fetch] 重新走完整拦截器链 (重新签名/附加 token);
/// 已重试次数记录在 RequestOptions.extra 中跨重试传递, 避免无限循环。
/// 重试次数/间隔实时读取 [NetworkTuning] (设置页变更立即生效, 无需重建)。
class RetryInterceptor extends Interceptor {
  final Dio _dio;

  RetryInterceptor(this._dio);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final retryCount = NetworkTuning.connectRetryCount;
    if (retryCount <= 0 || !_isConnectFailure(err)) {
      handler.next(err);
      return;
    }

    final attempted = _attemptCount(err);
    if (attempted >= retryCount) {
      handler.next(err);
      return;
    }

    // 延迟后重试 (经完整拦截器链重新签名/附 token)
    await Future<void>.delayed(
      Duration(milliseconds: NetworkTuning.connectRetryIntervalMs),
    );
    try {
      final response = await _dio.fetch<void>(
        err.requestOptions..extra['__retryAttempted'] = attempted + 1,
      );
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    } catch (_) {
      handler.next(err);
    }
  }

  /// 已重试次数 (记录在 RequestOptions.extra 中跨重试传递)
  static int _attemptCount(DioException err) {
    final v = err.requestOptions.extra['__retryAttempted'];
    return (v is int) ? v : 0;
  }

  /// 是否连接类失败 (请求未送达服务端, 重试安全)
  bool _isConnectFailure(DioException err) =>
      err.type == DioExceptionType.connectionTimeout ||
      err.type == DioExceptionType.connectionError;
}
