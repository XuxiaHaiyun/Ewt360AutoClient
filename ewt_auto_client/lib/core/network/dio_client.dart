/// 统一 Dio HTTP 客户端: 组装签名/认证/日志/重试拦截器, 包装 EWT360 网关
/// 响应 (ApiResponse) 与异常层次 (ApiException); 支持运行时切换代理、
/// 信任证书与 HTTP/2 (互斥, Web 平台回退浏览器原生栈)。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../constants/app_constants.dart';
import '../config/endpoint_config.dart';
import 'http2_adapter_stub.dart'
    if (dart.library.io) 'http2_adapter_io.dart' as h2;
import 'interceptors/auth_interceptor.dart';
import 'interceptors/sign_interceptor.dart';
import 'network_logger.dart';
import 'network_tuning.dart';
import 'proxy_adapter.dart';
import 'retry_interceptor.dart';

/// 统一 API 响应包装
///
/// EWT360 网关响应格式: {"success": true, "code": "200", "msg": "操作成功", "data": ...}
/// 部分旧接口返回: {"code": "00000", "msg": "success", "data": ...}
class ApiResponse<T> {
  final bool success;
  final String code;
  final String msg;
  final T? data;

  const ApiResponse({
    required this.success,
    required this.code,
    required this.msg,
    this.data,
  });

  bool get isSuccess => success || code == '00000' || code == '200';

  factory ApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic)? fromData,
  ) {
    return ApiResponse(
      success: json['success'] == true,
      code: json['code']?.toString() ?? '',
      msg: json['msg']?.toString() ?? '',
      data: json['data'] != null && fromData != null
          ? fromData(json['data'])
          : json['data'] as T?,
    );
  }
}

/// API 异常层次
sealed class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

/// 网络层异常（连接失败、超时等）
class NetworkException extends ApiException {
  const NetworkException(super.message);
}

/// 认证异常（token 过期、登录失败）
class AuthException extends ApiException {
  final String? code;
  const AuthException(super.message, {this.code});
}

/// 业务红线异常（触发风控）
class RedlineException extends ApiException {
  const RedlineException(super.message);
}

/// Dio HTTP 客户端工厂
///
/// 对应 Python: core/base.py EWTBaseClient 的 HTTP 会话管理
class DioClient {
  final Dio _dio;
  final AuthInterceptor _authInterceptor;
  final EndpointConfig _endpointConfig;

  /// 本客户端使用的 HTTP 代理 (`host:port`), null 表示直连
  ///
  /// 由调用方在创建时传入 (批量任务中每账号可配置不同代理)。
  /// Web 平台浏览器网络栈不可控, 代理配置被静默忽略。
  String? _proxy;

  /// 当前代理 (null = 直连; 供 DownloadService 等外部 dio 复用同一代理)
  String? get proxy => _proxy;

  /// 禁用 SSL 证书验证 (自签名证书/抓包场景)
  bool _trustAllCerts;

  /// 启用 HTTP/2 (仅当无代理且未禁用证书校验时生效, 否则回退 HTTP/1.1)
  bool _useHttp2;

  DioClient({
    required EndpointConfig endpointConfig,
    String? proxy,
    bool? trustAllCerts,
    bool enableHttp2 = false,
  })  : _endpointConfig = endpointConfig,
        _authInterceptor = AuthInterceptor(endpointConfig),
        _dio = Dio(BaseOptions(
          baseUrl: ApiConstants.gatewayDomain,
          connectTimeout: const Duration(seconds: AppConstants.defaultTimeout),
          receiveTimeout: const Duration(seconds: AppConstants.defaultTimeout),
          sendTimeout: const Duration(seconds: AppConstants.defaultTimeout),
          responseType: ResponseType.plain,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/plain, */*',
            'Accept-Encoding': 'gzip, deflate, br, zstd',
            'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8',
            'Connection': 'keep-alive',
          },
        )),
        _proxy = proxy,
        _trustAllCerts = trustAllCerts ?? NetworkTuning.trustAllCerts,
        _useHttp2 = enableHttp2 || NetworkTuning.enableHttp2 {
    _dio.interceptors.addAll([
      SignInterceptor(_endpointConfig),
      _authInterceptor,
      NetworkLogInterceptor(),
      RetryInterceptor(_dio),
    ]);
    _rebuildAdapter();
  }

  /// 动态开关网络日志（写入文件）
  static void setLoggingEnabled(bool enabled) {
    NetworkLogger.instance.setEnabled(enabled);
  }

  /// 获取日志文件路径
  static String? get logFilePath => NetworkLogger.instance.logFilePath;

  /// 设置当前 token
  set token(String? value) => _authInterceptor.token = value;
  String? get token => _authInterceptor.token;

  /// 运行时更新代理 (`host:port` / `http://host:port` / `socks5://host:port`)
  ///
  /// null/空串恢复直连。重建底层适配器立即生效 (仅替换引用,
  /// 旧适配器存量连接空闲后自然释放; Web 平台浏览器网络栈不可控, 静默忽略)。
  void updateProxy(String? proxy) {
    _proxy = (proxy == null || proxy.trim().isEmpty) ? null : proxy.trim();
    _rebuildAdapter();
  }

  /// 运行时切换"禁用 SSL 证书验证"
  void setTrustAllCerts(bool disabled) {
    if (_trustAllCerts == disabled) return;
    _trustAllCerts = disabled;
    _rebuildAdapter();
  }

  /// 运行时切换 HTTP/2 (与代理/禁用证书校验互斥, 冲突时回退 HTTP/1.1)
  void setHttp2Enabled(bool enabled) {
    if (_useHttp2 == enabled) return;
    _useHttp2 = enabled;
    _rebuildAdapter();
  }

  /// 重建底层网络适配器
  ///
  /// - HTTP/2 (Http2Adapter): 仅无代理且未禁用证书校验时启用
  ///   (Http2Adapter 不支持 findProxy 代理与 badCertificateCallback);
  ///   Web 平台适配器不可用, 回退浏览器原生栈;
  /// - 其余情况走 IOHttpClientAdapter (HTTP/1.1, 支持代理 + 证书策略)。
  /// 仅替换引用立即生效, 旧适配器存量连接空闲后自然释放。
  void _rebuildAdapter() {
    final useHttp2 =
        _useHttp2 && !_trustAllCerts && (_proxy == null || _proxy!.isEmpty);
    if (useHttp2) {
      final adapter = h2.createHttp2Adapter();
      if (adapter != null) {
        _dio.httpClientAdapter = adapter;
        return;
      }
    }
    applyProxyAdapter(_dio, _proxy, trustAllCerts: _trustAllCerts);
  }

  /// 暴露端点配置 (供 DownloadService 等需要构建下载 headers 的组件使用)
  EndpointConfig get endpointConfig => _endpointConfig;

  /// GET 请求
  Future<ApiResponse<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    T Function(dynamic)? fromData,
    Duration? timeout,
  }) async {
    try {
      final response = await _dio.get(
        path,
        queryParameters: queryParameters,
        options: Options(
          headers: headers,
          receiveTimeout: timeout,
        ),
      );
      return _parseResponse(response, fromData);
    } on DioException catch (e) {
      throw _handleDioError(e);
    } on FormatException catch (e) {
      throw NetworkException('响应格式异常: ${e.message}');
    }
  }

  /// POST 请求
  Future<ApiResponse<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    T Function(dynamic)? fromData,
    Duration? timeout,
  }) async {
    try {
      final response = await _dio.post(
        path,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          headers: headers,
          receiveTimeout: timeout,
        ),
      );
      return _parseResponse(response, fromData);
    } on DioException catch (e) {
      throw _handleDioError(e);
    } on FormatException catch (e) {
      throw NetworkException('响应格式异常: ${e.message}');
    }
  }

  /// 向非网关域名发送请求（BFE/CLOG/DLOG/playvideo 等）
  Future<Response> rawRequest(
    String method,
    String url, {
    dynamic data,
    Map<String, String>? headers,
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      final response = await _dio.request(
        url,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          method: method,
          headers: headers,
          // 遥测端点不需要网关签名，移除拦截器影响
          // 使用完整 URL 时 Dio 不会附加 baseUrl
        ),
      );
      return response;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  ApiResponse<T> _parseResponse<T>(
    Response response,
    T Function(dynamic)? fromData,
  ) {
    dynamic data = response.data;

    // responseType: plain → data 是 String，需手动解析 JSON
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        // 非 JSON 响应（HTML 错误页、纯文本等）
        return ApiResponse(
          success: false,
          code: '${response.statusCode ?? 0}',
          msg: '服务器返回非JSON响应',
        );
      }
    }

    if (data is Map<String, dynamic>) {
      return ApiResponse.fromJson(data, fromData);
    }
    return ApiResponse(success: true, code: '200', msg: 'ok', data: data as T?);
  }

  ApiException _handleDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return NetworkException('请求超时: ${e.message}');
      case DioExceptionType.connectionError:
        return NetworkException('网络连接失败: ${e.message}');
      case DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode ?? 0;
        if (statusCode == 401 || statusCode == 403) {
          return AuthException('认证失败 (HTTP $statusCode)');
        }
        return NetworkException('服务器错误 (HTTP $statusCode)');
      default:
        return NetworkException('网络异常: ${e.message}');
    }
  }
}
