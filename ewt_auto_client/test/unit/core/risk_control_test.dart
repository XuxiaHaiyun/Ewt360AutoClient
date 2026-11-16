/// 风控模块单元测试 (离线, 自包含)
///
/// 覆盖:
///   - [RiskControlConfig]: JSON 解析 / 默认值 / 启动密码 / 功能开关
///   - [VariantBase64]: 变种 Base64 编解码往返
///   - [RiskControlCrypto]: encrypt/decrypt 往返 + 与 Python 密文交叉验证
///
/// 交叉验证测试读取 `risk_control/encrypted_config.txt` (Python 生成),
/// 文件存在时执行, 缺失时自动跳过, 不阻塞其余自包含测试。
library;

import 'dart:io';

import 'package:ewt_auto_client/core/risk_control/risk_control_config.dart';
import 'package:ewt_auto_client/core/risk_control/risk_control_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VariantBase64', () {
    test('标准字节编码后能还原 (往返一致)', () {
      final bytes = [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0xFF, 0x80];
      final encoded = VariantBase64.encode(bytes);
      expect(encoded, isNot(contains('+/')), reason: '不使用标准字母表顺序');
      expect(VariantBase64.decode(encoded), bytes);
    });

    test('空字节往返', () {
      expect(VariantBase64.decode(VariantBase64.encode([])), isEmpty);
    });

    test('编码结果不含标准 Base64 字符映射特征', () {
      // "Hello" 标准 Base64 = "SGVsbG8=", 变种应完全不同
      final encoded = VariantBase64.encode('Hello'.codeUnits);
      expect(encoded, isNot('SGVsbG8='));
      // padding '=' 保持不变
      expect(encoded.endsWith('='), isTrue);
    });
  });

  group('RiskControlCrypto', () {
    test('encrypt/decrypt 往返一致 (含中文与换行)', () {
      const json = '{"app": {"enabled": true}, "features": {"homework": {"report": true}}}';
      final encrypted = RiskControlCrypto.encrypt(json);
      expect(encrypted, startsWith('@'));
      expect(encrypted, endsWith('@'));
      expect(RiskControlCrypto.decrypt(encrypted), json);
    });

    test('decrypt 容忍多余空白与缺失标记', () {
      const json = '{"a":1}';
      final encrypted = RiskControlCrypto.encrypt(json);
      // 含首尾空白
      expect(RiskControlCrypto.decrypt('  \n$encrypted\r\n  '), json);
      // 仅密文体 (剥掉标记)
      final body = encrypted
          .split('\n')
          .where((l) => !l.startsWith('@'))
          .join();
      expect(RiskControlCrypto.decrypt(body), json);
    });

    test('不同明文产生不同密文', () {
      final a = RiskControlCrypto.encrypt('{"x":1}');
      final b = RiskControlCrypto.encrypt('{"x":2}');
      expect(a, isNot(b));
    });

    test('与 Python 生成密文交叉验证 (文件存在时)', () {
      final encryptedFile = File('risk_control/encrypted_config.txt');
      final originalFile = File('risk_control/risk_control_config.json');
      if (!encryptedFile.existsSync() || !originalFile.existsSync()) {
        markTestSkipped('缺少 Python 生成的 risk_control/*.txt 参考文件');
        return;
      }
      final encrypted = encryptedFile.readAsStringSync();
      final original = originalFile.readAsStringSync();
      // Python -> Dart: 解密应还原原始 JSON
      expect(RiskControlCrypto.decrypt(encrypted), original);
      // Dart 加密结果应与 Python 一致 (仅换行差异)
      final dartEncrypted = RiskControlCrypto.encrypt(original);
      expect(
        dartEncrypted.replaceAll('\r\n', '\n'),
        encrypted.replaceAll('\r\n', '\n'),
      );
    });
  });

  group('RiskControlConfig', () {
    test('默认配置: 启用 + 无密码 + 无功能限制', () {
      const cfg = RiskControlConfig();
      expect(cfg.enabled, isTrue);
      expect(cfg.hasStartupPassword, isFalse);
      expect(cfg.isAppEnabled(), isTrue);
      expect(cfg.isExpired(), isFalse);
    });

    test('fromJson 解析 app 字段 (enabled/password/expire)', () {
      final cfg = RiskControlConfig.fromJson({
        'app': {
          'enabled': true,
          'startup_password': '1234',
          'startup_password_prompt': '输入密码',
          'expire_at': '2999-01-01 00:00:00',
        },
      });
      expect(cfg.isAppEnabled(), isTrue);
      expect(cfg.hasStartupPassword, isTrue);
      expect(cfg.startupPassword, '1234');
      expect(cfg.startupPasswordPrompt, '输入密码');
      expect(cfg.isExpired(), isFalse);
      expect(cfg.expireAt, isNotNull);
    });

    test('fromJson: enabled=false 时整体停用', () {
      final cfg = RiskControlConfig.fromJson({
        'app': {'enabled': false},
        'features': {'a': {'b': true}},
      });
      expect(cfg.isAppEnabled(), isFalse);
      expect(cfg.isFeatureEnabled('a.b'), isFalse,
          reason: '整体停用时功能开关一律关闭');
    });

    test('过期配置: isExpired() 为 true', () {
      final cfg = RiskControlConfig.fromJson({
        'app': {'expire_at': '2000-01-01 00:00:00'},
      });
      expect(cfg.isExpired(), isTrue);
    });

    test('非法日期格式回退为 null (不过期)', () {
      final cfg = RiskControlConfig.fromJson({
        'app': {'expire_at': 'not-a-date'},
      });
      expect(cfg.expireAt, isNull);
      expect(cfg.isExpired(), isFalse);
    });

    test('启动密码校验: 匹配才通过', () {
      const cfg = RiskControlConfig(startupPassword: 's3cret');
      expect(cfg.verifyStartupPassword('s3cret'), isTrue);
      expect(cfg.verifyStartupPassword('wrong'), isFalse);
      expect(cfg.verifyStartupPassword(''), isFalse);
    });

    test('isFeatureEnabled 按 group.item 解析', () {
      const cfg = RiskControlConfig(features: {
        'homework': {'report': true, 'answer': false},
      });
      expect(cfg.isFeatureEnabled('homework.report'), isTrue);
      expect(cfg.isFeatureEnabled('homework.answer'), isFalse);
      expect(cfg.isFeatureEnabled('homework.missing'), isFalse);
      expect(cfg.isFeatureEnabled('no_dot_key'), isFalse);
    });

    test('fromJson features 数值 true/false 正确归一', () {
      final cfg = RiskControlConfig.fromJson({
        'features': {
          'player': {'fast': true, 'slow': false, 'truthy': 1},
        },
      });
      expect(cfg.isFeatureEnabled('player.fast'), isTrue);
      expect(cfg.isFeatureEnabled('player.slow'), isFalse);
      expect(cfg.isFeatureEnabled('player.truthy'), isFalse,
          reason: '仅布尔 true 生效');
    });
  });
}
