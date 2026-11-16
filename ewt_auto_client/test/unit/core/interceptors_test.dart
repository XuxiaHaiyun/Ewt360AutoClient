/// 网络拦截器单元测试 (离线)
///
/// 通过自定义 [HttpClientAdapter] 捕获请求, 验证:
///   - [SignInterceptor]: timestamp / sign / secretId / platform 头注入
///   - [AuthInterceptor]: token / UA / Origin / Referer / 额外 headers 注入
///
/// 不发起真实网络请求 (MockAdapter 直接返回固定响应)。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/crypto/crypto_utils.dart';
import 'package:ewt_auto_client/core/network/interceptors/auth_interceptor.dart';
import 'package:ewt_auto_client/core/network/interceptors/sign_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 捕获请求但不真正发送的 HttpClientAdapter
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'code': '200', 'msg': 'ok'}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late EndpointConfig config;
  late _RecordingAdapter adapter;
  late Dio dio;

  setUp(() {
    config = EndpointConfig.defaults();
    adapter = _RecordingAdapter();
    dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
      ..httpClientAdapter = adapter
      ..interceptors.addAll([
        SignInterceptor(config),
        AuthInterceptor(config),
      ]);
  });

  RequestOptions lastRequest() => adapter.requests.single;

  group('SignInterceptor', () {
    test('注入 timestamp / sign / secretId / platform', () async {
      await dio.get('/api/test');
      final headers = lastRequest().headers;

      final timestamp = int.parse(headers['timestamp']! as String);
      expect(timestamp, greaterThan(0));
      expect(headers['sign'], RequestSigner.generateSign(timestamp, config.secretKey));
      expect(headers['secretId'], config.secretId);
      expect(headers['platform'], config.platform);
    });

    test('签名可由 timestamp + secretKey 独立复算', () async {
      await dio.get('/api/test');
      final headers = lastRequest().headers;
      final ts = int.parse(headers['timestamp']! as String);
      final sign = headers['sign']! as String;
      expect(sign, RequestSigner.generateSign(ts, config.secretKey));
      expect(sign, matches(RegExp(r'^[0-9A-F]{32}$')));
    });

    test('连续两次请求签名不同 (时间戳敏感)', () async {
      await dio.get('/a');
      await dio.get('/b');
      final signs = adapter.requests.map((r) => r.headers['sign']).toSet();
      expect(signs.length, 2, reason: '两次请求 sign 应不同');
    });
  });

  group('AuthInterceptor', () {
    test('未设置 token 时注入 "0"', () async {
      await dio.get('/api/test');
      expect(lastRequest().headers['token'], '0');
    });

    test('设置 token 后注入实际 token', () async {
      final auth = dio.interceptors.firstWhere(
        (i) => i is AuthInterceptor,
      ) as AuthInterceptor;
      auth.token = 'abc123';
      await dio.get('/api/test');
      expect(lastRequest().headers['token'], 'abc123');
    });

    test('注入 UA / Origin / Referer', () async {
      await dio.get('/api/test');
      final headers = lastRequest().headers;
      expect(headers['User-Agent'], config.userAgent);
      expect(headers['Origin'], config.origin);
      expect(headers['Referer'], config.referer);
    });

    test('注入端点额外 headers (sec-ch-ua 等)', () async {
      await dio.get('/api/test');
      final headers = lastRequest().headers;
      for (final entry in config.extraHeaders.entries) {
        expect(headers[entry.key], entry.value,
            reason: '缺少 header: ${entry.key}');
      }
    });

    test('保留调用方已设置的 headers', () async {
      await dio.get('/api/test', options: Options(headers: {'X-Custom': 'keep'}));
      final headers = lastRequest().headers;
      expect(headers['X-Custom'], 'keep');
      expect(headers['token'], '0');
    });
  });
}
