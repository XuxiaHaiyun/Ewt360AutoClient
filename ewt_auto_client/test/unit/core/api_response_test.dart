/// 网络响应与异常单元测试 (离线)
///
/// 覆盖 [ApiResponse] 统一响应包装的解析逻辑,
/// 以及 [ApiException] sealed 异常层次的可穷尽分支。
library;

import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiResponse.fromJson', () {
    test('解析标准 EWT360 网关成功响应', () {
      final resp = ApiResponse.fromJson(
        {'success': true, 'code': '200', 'msg': '操作成功', 'data': {'a': 1}},
        null,
      );
      expect(resp.success, isTrue);
      expect(resp.code, '200');
      expect(resp.msg, '操作成功');
      expect(resp.data, {'a': 1});
      expect(resp.isSuccess, isTrue);
    });

    test('解析旧版 code=00000 响应 (无 success 字段)', () {
      final resp = ApiResponse.fromJson(
        {'code': '00000', 'msg': 'success', 'data': 'ok'},
        null,
      );
      expect(resp.success, isFalse);
      expect(resp.isSuccess, isTrue, reason: 'code=00000 视为成功');
    });

    test('isSuccess 兼容 code=200 与 success=false', () {
      final r1 = ApiResponse.fromJson({'code': '200', 'data': null}, null);
      expect(r1.isSuccess, isTrue);
      final r2 = ApiResponse.fromJson(
        {'success': false, 'code': '500', 'msg': 'err'},
        null,
      );
      expect(r2.isSuccess, isFalse);
    });

    test('fromData 转换器在 data 非空时被调用', () {
      final resp = ApiResponse.fromJson(
        {'success': true, 'code': '200', 'data': '42'},
        (d) => int.parse(d as String),
      );
      expect(resp.data, 42);
    });

    test('data 为 null 时不调用 fromData', () {
      final resp = ApiResponse.fromJson(
        {'success': true, 'code': '200', 'data': null},
        (d) => throw StateError('不应被调用'),
      );
      expect(resp.data, isNull);
    });

    test('code/msg 数值或缺失时安全转换', () {
      final resp = ApiResponse.fromJson({'code': 200, 'data': 1}, null);
      expect(resp.code, '200');
      expect(resp.msg, '');
    });
  });

  group('ApiException 层次', () {
    test('三种异常均为 ApiException 且 message 可读', () {
      const exceptions = <ApiException>[
        NetworkException('网络失败'),
        AuthException('认证失败'),
        RedlineException('触发风控'),
      ];
      for (final e in exceptions) {
        expect(e, isA<ApiException>());
        expect(e.message, isNotEmpty);
        expect(e.toString(), e.message);
      }
    });

    test('AuthException 可携带错误码', () {
      const e = AuthException('token 过期', code: '401');
      expect(e.code, '401');
    });

    test('sealed 类型可被 switch 穷尽 (编译期保证)', () {
      String describe(ApiException e) => switch (e) {
            NetworkException() => 'network',
            AuthException() => 'auth',
            RedlineException() => 'redline',
          };
      expect(describe(const NetworkException('x')), 'network');
      expect(describe(const AuthException('x')), 'auth');
      expect(describe(const RedlineException('x')), 'redline');
    });
  });
}
