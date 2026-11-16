/// ApiHelper 网络层工具单元测试 (离线)
library;

import 'package:ewt_auto_client/core/network/api_helper.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiHeaders', () {
    test('web 站点头指向 web.ewt360.com', () {
      expect(ApiHeaders.web['Origin'], 'https://web.ewt360.com');
      expect(ApiHeaders.web['Referer'], 'https://web.ewt360.com/');
    });

    test('teacher 站点头指向 teacher.ewt360.com', () {
      expect(ApiHeaders.teacher['Origin'], 'https://teacher.ewt360.com');
      expect(ApiHeaders.teacher['Referer'], 'https://teacher.ewt360.com/');
    });

    test('www 站点头指向 www.ewt360.com', () {
      expect(ApiHeaders.www['Origin'], 'https://www.ewt360.com');
      expect(ApiHeaders.www['Referer'], 'https://www.ewt360.com/');
    });
  });

  group('parseInt / parseString / parseBool', () {
    test('parseInt 支持 int/double/数字字符串', () {
      expect(ApiHelper.parseInt(5), 5);
      expect(ApiHelper.parseInt(3.7), 3);
      expect(ApiHelper.parseInt('42'), 42);
      expect(ApiHelper.parseInt('12.9'), 12);
    });

    test('parseInt 非法输入回退默认值', () {
      expect(ApiHelper.parseInt(null), 0);
      expect(ApiHelper.parseInt('abc'), 0);
      expect(ApiHelper.parseInt('abc', -1), -1);
      expect(ApiHelper.parseIntOrNull('abc'), isNull);
    });

    test('parseString 非 null 值一律 toString', () {
      expect(ApiHelper.parseString('x'), 'x');
      expect(ApiHelper.parseString(123), '123');
      expect(ApiHelper.parseString(true), 'true');
      expect(ApiHelper.parseString(null), '');
      expect(ApiHelper.parseString(null, 'fb'), 'fb');
    });

    test('parseBool 支持 bool/0-1/字符串', () {
      expect(ApiHelper.parseBool(true), isTrue);
      expect(ApiHelper.parseBool(1), isTrue);
      expect(ApiHelper.parseBool(0), isFalse);
      expect(ApiHelper.parseBool('true'), isTrue);
      expect(ApiHelper.parseBool('1'), isTrue);
      expect(ApiHelper.parseBool('false'), isFalse);
      expect(ApiHelper.parseBool(null), isFalse);
      expect(ApiHelper.parseBool('unknow', true), isTrue);
    });
  });

  group('ensureData / ensureSuccess / ensureList', () {
    ApiResponse<dynamic> ok(Map<String, dynamic> data) =>
        ApiResponse(success: true, code: '200', msg: 'ok', data: data);

    ApiResponse<dynamic> fail() =>
        ApiResponse(success: false, code: '500', msg: '服务器错误');

    test('ensureData 成功返回 data map', () {
      final r = ok({'a': 1});
      expect(ApiHelper.ensureData(r, 'x')['a'], 1);
    });

    test('ensureData 失败抛 NetworkException 且带前缀', () {
      expect(
        () => ApiHelper.ensureData(fail(), '查询失败'),
        throwsA(isA<NetworkException>().having(
          (e) => e.message,
          'message',
          contains('查询失败'),
        )),
      );
    });

    test('ensureData data 非 Map 时返回 fallback', () {
      final r = ok({'a': 1});
      // 模拟 data 为 List 的情况
      final r2 = ApiResponse(success: true, code: '200', msg: 'ok', data: [1]);
      expect(ApiHelper.ensureData(r2, 'x'), isEmpty);
    });

    test('ensureSuccess 返回原始 data', () {
      final r = ApiResponse(success: true, code: '200', msg: 'ok', data: 'tok');
      expect(ApiHelper.ensureSuccess(r, 'x'), 'tok');
    });

    test('ensureList 返回 List<Map>', () {
      final r = ApiResponse(
        success: true,
        code: '200',
        msg: 'ok',
        data: [
          {'id': 1},
          {'id': 2},
        ],
      );
      final list = ApiHelper.ensureList(r, 'x');
      expect(list.length, 2);
      expect(list.first['id'], 1);
    });

    test('ensureList 非 List 时返回 fallback', () {
      expect(ApiHelper.ensureList(ok({'a': 1}), 'x'), isEmpty);
    });
  });
}
