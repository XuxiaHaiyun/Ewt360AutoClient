/// EndpointConfig 单元测试 (离线)
///
/// 覆盖默认配置 / JSON 加载 / 动态更新 / 固定 WEB 端点常量。
library;

import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/constants/crypto_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EndpointConfig.defaults()', () {
    test('使用固定 WEB 端点 (secretId=2, platform=1)', () {
      final cfg = EndpointConfig.defaults();
      expect(cfg.secretId, CryptoConstants.webSecretId);
      expect(cfg.platform, CryptoConstants.webPlatform);
      expect(cfg.secretKey, CryptoConstants.webSignSecretKey);
    });

    test('提供浏览器 UA 与 sdkVersion', () {
      final cfg = EndpointConfig.defaults();
      expect(cfg.userAgent, contains('Mozilla/5.0'));
      expect(cfg.sdkVersion, '3.0.37');
    });

    test('Origin/Referer 指向 www.ewt360.com', () {
      final cfg = EndpointConfig.defaults();
      expect(cfg.origin, 'https://www.ewt360.com');
      expect(cfg.referer, 'https://www.ewt360.com/');
    });

    test('默认携带 sec-ch-ua 等额外 headers', () {
      final cfg = EndpointConfig.defaults();
      expect(cfg.extraHeaders, contains('sec-ch-ua'));
      expect(cfg.extraHeaders, contains('sec-ch-ua-platform'));
      expect(cfg.extraHeaders['DNT'], '1');
    });

    test('心跳间隔为 60 秒', () {
      expect(EndpointConfig.defaults().reportInterval, 60);
    });
  });

  group('EndpointConfig.fromJson()', () {
    test('解析 web_device_info.json 格式 (api + headers)', () {
      final cfg = EndpointConfig.fromJson({
        'api': {
          'user_agent': 'Mozilla/5.0 TestUA',
          'sdk_version': '1.2.3',
        },
        'headers': {
          'X-Custom': 'yes',
          'X-Num': 42,
        },
      });
      expect(cfg.userAgent, 'Mozilla/5.0 TestUA');
      expect(cfg.sdkVersion, '1.2.3');
      expect(cfg.extraHeaders['X-Custom'], 'yes');
      expect(cfg.extraHeaders['X-Num'], '42'); // 数值转为字符串
    });

    test('缺失字段回退默认值', () {
      final cfg = EndpointConfig.fromJson({});
      expect(cfg.userAgent, contains('Mozilla/5.0'));
      expect(cfg.sdkVersion, '3.0.37');
      expect(cfg.extraHeaders, isEmpty);
    });

    test('headers 为空 map 时无额外 header', () {
      final cfg = EndpointConfig.fromJson({'api': {}, 'headers': {}});
      expect(cfg.extraHeaders, isEmpty);
    });
  });

  group('EndpointConfig.update()', () {
    test('仅更新传入字段, 其余保持不变', () {
      final cfg = EndpointConfig.defaults();
      final before = cfg.userAgent;
      cfg.update(sdkVersion: '9.9.9');
      expect(cfg.userAgent, before);
      expect(cfg.sdkVersion, '9.9.9');
    });

    test('可整体替换 extraHeaders', () {
      final cfg = EndpointConfig.defaults();
      cfg.update(extraHeaders: {'Only': 'One'});
      expect(cfg.extraHeaders.length, 1);
      expect(cfg.extraHeaders['Only'], 'One');
    });
  });
}
