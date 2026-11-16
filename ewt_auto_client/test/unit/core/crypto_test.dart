/// 加密/签名工具单元测试 (离线)
///
/// 覆盖 [PasswordEncryptor] / [RequestSigner] / [BfeSigner] / [DlogSigner]。
/// golden 向量由 Python (hashlib/hmac + pycryptodome) 独立生成,
/// 确保 Dart 实现与 Python 版本逐字节一致。
library;

import 'package:ewt_auto_client/core/crypto/crypto_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PasswordEncryptor (AES-256-CBC + PKCS7 → 大写 HEX)', () {
    test('加密结果与 Python golden 向量一致', () {
      expect(PasswordEncryptor.encrypt('123456'), 'A7428361DEF118911783F446A129FFCE');
      expect(
        PasswordEncryptor.encrypt('admin123'),
        '7B90B56523F0ABAF67E41F44D3F2EF15',
      );
    });

    test('含中文密码正确加密 (UTF-8 编码)', () {
      expect(
        PasswordEncryptor.encrypt('Ewt@2026!测试'),
        'F4F4DC48C9F33C33F371936978823F3F',
      );
    });

    test('输出为大写 HEX, 长度为 16 字节块对齐的 2 倍', () {
      final out = PasswordEncryptor.encrypt('123456');
      expect(out, matches(RegExp(r'^[0-9A-F]+$')));
      expect(out.length, 32); // 6 字节明文 → 1 个 AES 块 → 32 hex
    });

    test('同一密码加密结果确定 (无随机 IV)', () {
      expect(
        PasswordEncryptor.encrypt('fixed-password'),
        PasswordEncryptor.encrypt('fixed-password'),
      );
    });

    test('不同密码产生不同密文', () {
      expect(
        PasswordEncryptor.encrypt('abc'),
        isNot(PasswordEncryptor.encrypt('abd')),
      );
    });
  });

  group('RequestSigner (MD5 请求签名)', () {
    test('与 Python golden 向量一致', () {
      expect(RequestSigner.generateSign(1700000000000, 'bdc739ff2dcf'),
          '42037ECA0FF8EE7D466ADBC3DDE2B32A');
    });

    test('输出为大写 MD5 hex (32 字符)', () {
      final sign = RequestSigner.generateSign(1700000000000, 'secret');
      expect(sign, matches(RegExp(r'^[0-9A-F]{32}$')));
    });

    test('同一输入结果确定', () {
      expect(
        RequestSigner.generateSign(1700000000000, 'secret'),
        RequestSigner.generateSign(1700000000000, 'secret'),
      );
    });

    test('时间戳变化导致签名变化', () {
      expect(
        RequestSigner.generateSign(1, 'secret'),
        isNot(RequestSigner.generateSign(2, 'secret')),
      );
    });

    test('generateTimestamp 返回毫秒级时间戳', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final ts = RequestSigner.generateTimestamp();
      final after = DateTime.now().millisecondsSinceEpoch;
      expect(ts, inInclusiveRange(before, after));
    });
  });

  group('BfeSigner (HMAC-SHA1 遥测签名)', () {
    test('与 Python golden 向量一致 (40 位小写 hex)', () {
      expect(
        BfeSigner.signCollect(
          secret: 'testsecret',
          token: 'tok123',
          action: 2,
          duration: 60,
          timestamp: 1700000000000,
        ),
        '6e689703fc32662511507d53ecbdefe2dc080eda',
      );
    });

    test('签名串按字段字典序固定, 参数变化改变签名', () {
      final base = BfeSigner.signCollect(
        secret: 's',
        token: 't',
        action: 1,
        duration: 10,
        timestamp: 100,
      );
      final changed = BfeSigner.signCollect(
        secret: 's',
        token: 't',
        action: 2,
        duration: 10,
        timestamp: 100,
      );
      expect(base, isNot(changed));
    });
  });

  group('DlogSigner (MD5 日志签名)', () {
    test('与 Python golden 向量一致', () {
      // golden 由 Python hashlib.md5('log={json}&key={dlogSignKey}') 独立验证
      // (2026-08 校准: 旧 golden 基于历史 key 生成, 与当前 dlogSignKey 不匹配)
      expect(DlogSigner.sign('{"a":1}'), '7aa46f2a472987634c91508bdc83b2eb');
      expect(
        DlogSigner.sign('{"userid":"10001","action":1}'),
        '108fa84eee1d95d715f01f1e361ee07d',
      );
    });

    test('输出为 32 位小写 hex', () {
      expect(DlogSigner.sign('{}'), matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('日志内容变化导致签名变化', () {
      expect(DlogSigner.sign('{"a":1}'), isNot(DlogSigner.sign('{"a":2}')));
    });
  });
}
