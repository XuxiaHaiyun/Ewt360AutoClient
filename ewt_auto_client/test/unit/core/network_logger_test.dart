/// NetworkLogger 单元测试 (离线, 不依赖真实文件系统)
///
/// 聚焦拦截器日志格式与敏感字段脱敏逻辑; 文件落盘由异步队列承担,
/// 不在此验证实际写入。
library;

import 'package:ewt_auto_client/core/network/network_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NetworkLogInterceptor 脱敏', () {
    // 通过拦截器触发日志, 但 NetworkLogger 默认关闭 → 用私有静态方法直接验证

    test('Map 中 token/password 字段被脱敏', () {
      final masked = NetworkLogInterceptor.debugMask({
        'token': 'abc123',
        'userName': '张三',
        'password': 'p@ss',
        'nested': {
          'secret': 'xyz',
          'ok': 'keep',
        },
        'list': [
          {'captchaToken': 'cap-1', 'id': 1},
        ],
      });
      expect(masked['token'], '***');
      expect(masked['password'], '***');
      expect(masked['userName'], '张三');
      expect((masked['nested'] as Map)['secret'], '***');
      expect((masked['nested'] as Map)['ok'], 'keep');
      expect(((masked['list'] as List).first as Map)['captchaToken'], '***');
      expect(((masked['list'] as List).first as Map)['id'], 1);
    });
  });

  group('NetworkLogInterceptor 日志格式', () {
    test('时间戳为 HH:mm:ss.SSS 格式', () {
      final ts = NetworkLogInterceptor.debugTimestamp();
      expect(ts, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3}$')));
    });
  });
}
