/// RetryInterceptor 连接重试单元测试 (fake adapter, 离线)
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ewt_auto_client/core/network/network_tuning.dart';
import 'package:ewt_auto_client/core/network/retry_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可编程失败次数/失败类型的假适配器
class _FakeAdapter implements HttpClientAdapter {
  int calls = 0;
  final int failTimes;
  final DioExceptionType failType;

  _FakeAdapter({required this.failTimes, this.failType = DioExceptionType.connectionError});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (calls <= failTimes) {
      throw DioException(
        requestOptions: options,
        type: failType,
        error: 'fake failure #$calls',
      );
    }
    return ResponseBody.fromString('{"ok":true}', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() {
    NetworkTuning.update(retryCount: 0, retryIntervalMs: 1);
  });

  Dio buildDio(_FakeAdapter adapter) {
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(RetryInterceptor(dio));
    return dio;
  }

  test('连接失败后按次数重试, 重试成功返回', () async {
    NetworkTuning.update(retryCount: 2, retryIntervalMs: 1);
    final adapter = _FakeAdapter(failTimes: 1);
    final dio = buildDio(adapter);

    final res = await dio.get<Object?>('/x');

    expect(res.statusCode, 200);
    expect(adapter.calls, 2, reason: '初次 + 1 次重试');
  });

  test('重试次数耗尽后抛出, 总调用数 = 1 + 重试次数', () async {
    NetworkTuning.update(retryCount: 2, retryIntervalMs: 1);
    final adapter = _FakeAdapter(failTimes: 99);
    final dio = buildDio(adapter);

    await expectLater(dio.get<Object?>('/x'), throwsA(isA<DioException>()));
    expect(adapter.calls, 3, reason: '初次 + 2 次重试');
  });

  test('retryCount=0 时不重试', () async {
    NetworkTuning.update(retryCount: 0);
    final adapter = _FakeAdapter(failTimes: 3);
    final dio = buildDio(adapter);

    await expectLater(dio.get<Object?>('/x'), throwsA(isA<DioException>()));
    expect(adapter.calls, 1);
  });

  test('响应类错误 (badResponse) 不重试', () async {
    NetworkTuning.update(retryCount: 3, retryIntervalMs: 1);
    final adapter = _FakeAdapter(
      failTimes: 3,
      failType: DioExceptionType.badResponse,
    );
    final dio = buildDio(adapter);

    await expectLater(dio.get<Object?>('/x'), throwsA(isA<DioException>()));
    expect(adapter.calls, 1, reason: '服务端已响应, 不允许重试');
  });
}
