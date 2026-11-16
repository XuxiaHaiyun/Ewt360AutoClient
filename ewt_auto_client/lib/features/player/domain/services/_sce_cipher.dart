/// 阿里云私有加密 (AliyunVoDEncryption) 客户端密钥链的 Dart 原生重实现，
/// 逆向自 mst-player webpack 模块 120 的三个混淆函数（已逐位比对通过）。
/// 提供 genClientSecret / deriveRand / deriveVpk，派生出 HLS AES-128 密钥。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// 阿里云私有加密 (AliyunVoDEncryption) 客户端密钥链 — Dart 原生重实现
///
/// 逆向自 mst-player `mstplayer-v3.0.37.min.js` webpack 模块 120 导出的三个
/// 混淆函数 (均已实测逐位比对通过):
///
/// | 站点函数          | 语义                                            | 对应方法
/// |-------------------|-------------------------------------------------|-------------------------
/// | `_sce_r_skjhfnck` | 生成 16 字符客户端密钥材料 `l`                  | [SceCipher.genClientSecret]
/// | `_sce_lgtcaygl`   | `Rand = RSA-PKCS1v1.5(PK)` — 站点内嵌 512 位公钥 | [SceCipher.deriveRand]
/// | `_sce_dlgtqred`   | 由 `(l, 响应Rand, Plaintext)` 派生 HLS AES 密钥  | [SceCipher.deriveVpk]
///
/// ## 完整链路
///
/// ```text
/// l         = 16 字符随机串 (固定字符集, 剔除 I/L/O/U/V 等易混字符)
/// Rand_req  = base64(RSA-PKCS1v1.5_pub(l))            → 随 GetPlayInfo 请求发出
/// 服务端    用私钥解出 l, 校验通过才下发密钥素材
/// Rand_res  = base64(AES-128-CBC_k1(iv=k1)(Y))         → 32 字节, 随响应下发
/// Plaintext = base64(AES-128-CBC_k2(iv=k1)(base64(key))) → 32 字节, 随响应下发
///
///   k1 = utf8(md5_hex(l)[8:24])
///   Y  = utf8(AES_dec(k1, iv=k1, Rand_res))        ← 服务端选取的随机加盐串
///   k2 = utf8(md5_hex(l + Y)[8:24])
///   G  = utf8(AES_dec(k2, iv=k1, Plaintext))       ← 内容为 base64(16 字节密钥)
///   key = base64_decode(G)                          ← 最终 HLS AES-128 密钥
/// ```
///
/// ## 实现要点 (与 crypto-js / jsencrypt 行为逐条对齐)
///
/// - MD5 摘要取 **小写 hex** 的 `[8, 24)` 子串作为密钥字符串 (即中间 16 个 hex 字符),
///   再按 UTF-8 编码成 16 字节密钥。
/// - 两次 AES 均使用同一个 IV = k1; 只有第二次换用 k2 作密钥。
/// - 响应侧的 `Rand` 可能含换行 (jsencrypt 旧版输出会折行), 解密前需剔除 `\r\n`。
/// - 去填充采用 crypto-js 的宽松策略 (仅读末字节截断), 而非严格校验 PKCS7 —
///   保证密钥错误时行为与站点一致 (不会抛异常)。
///
/// ## 参考: 站点同款 RSA 公钥 (512 位, e=65537)
///
/// ```text
/// -----BEGIN PUBLIC KEY-----
/// MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAIcLeIt2wmIyXckgNhCGpMTAZyBGO+nk0/IdOrhIdfRR
/// gBLHdydsftMVPNHrRuPKQNZRslWE1vvgx80w9lCllIUCAwEAAQ==
/// -----END PUBLIC KEY-----
/// ```
class SceCipher {
  SceCipher._();

  /// 客户端密钥材料字符集 (还原自 `e[1]` 混淆串: 每项 charCode - 422)
  ///
  /// 共 50 个字符, 剔除了 I/L/O/U/V/i/l/o/q/u/v/1 等易混淆字形。
  static const String _charset =
      'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz234567890';

  /// 客户端密钥材料长度 (还原自 `441 - 0b110101001`)
  static const int secretLength = 16;

  /// RSA 公钥模数 n (512 位)
  static final BigInt _rsaModulus = BigInt.parse(
    '870b788b76c262325dc920361086a4c4c06720463be9e4d3f21d3ab84875f451'
    '8012c777276c7ed3153cd1eb46e3ca40d651b25584d6fbe0c7cd30f650a59485',
    radix: 16,
  );

  /// RSA 公钥指数 e = 65537
  static final BigInt _rsaExponent = BigInt.from(65537);

  /// RSA 密文字节长度 (= 模数字节数, 64)
  static final int _rsaBlockSize = (_rsaModulus.bitLength + 7) >> 3;

  /// 默认安全随机源
  static final Random _secureRandom = Random.secure();

  /// 生成客户端密钥材料 `l`
  ///
  /// 站点 (`_sce_r_skjhfnck`) 为 16 字符随机串, 逐字符取自 [_charset]。
  /// [rng] 可注入固定种子随机源 (单测用); 默认使用 [Random.secure]。
  static String genClientSecret({Random? rng}) {
    final rand = rng ?? _secureRandom;
    final buf = StringBuffer();
    for (var i = 0; i < secretLength; i++) {
      buf.write(_charset[rand.nextInt(_charset.length)]);
    }
    return buf.toString();
  }

  /// 由客户端密钥材料派生请求用 `Rand`
  ///
  /// 站点 (`_sce_lgtcaygl`) 为 `RSA-PKCS#1 v1.5 (type 2)` 加密, 输出 base64 的
  /// 64 字节密文 (88 字符)。填充区为随机非零字节, 因此同一输入每次结果不同 —
  /// 这是服务端识别"第三方自造随机字节"的凭据, 必须真实跑公钥加密。
  ///
  /// [secret] 最长 53 字节 (64 - 11), 超出返回 null (对齐 jsencrypt 行为)。
  static String? deriveRand(String secret, {Random? rng}) {
    final msg = Uint8List.fromList(utf8.encode(secret));
    final k = _rsaBlockSize;
    if (msg.length > k - 11) return null;

    final em = Uint8List(k);
    em[0] = 0x00;
    em[1] = 0x02;
    // PS: 随机非零字节, 占 [2, k - msg.length - 1)
    final rand = rng ?? _secureRandom;
    for (var i = 2; i < k - msg.length - 1; i++) {
      var b = 0;
      while (b == 0) {
        b = rand.nextInt(256);
      }
      em[i] = b;
    }
    em[k - msg.length - 1] = 0x00;
    em.setRange(k - msg.length, k, msg);

    final m = _bytesToBigInt(em);
    final c = m.modPow(_rsaExponent, _rsaModulus);
    return base64.encode(_bigIntToBytes(c, k));
  }

  /// 由 `(secret, 响应Rand, Plaintext)` 派生 HLS AES-128 密钥
  ///
  /// 站点 (`_sce_dlgtqred`) 返回字节数组 (本实现返回 [Uint8List]), 长度为
  /// [Plaintext] 内层 base64 解出的字节数 — 阿里云线路恒为 16 字节。
  ///
  /// [rand] 与 [plaintext] 均来自 GetPlayInfo 响应中该码流条目自身携带的字段
  /// (注意: 不是请求里发出的那个 Rand)。
  ///
  /// 密钥素材与组合不匹配时 (换 Cipher/下错档) 不会抛异常 — 对齐 crypto-js
  /// 的宽松解码; 此时返回空或长度异常的结果, 由调用方判断是否可用。
  static Uint8List deriveVpk({
    required String secret,
    required String rand,
    required String plaintext,
  }) {
    final k1 = _keyOfMd5(secret);
    final y = _aesCbcDecryptUtf8(rand, key: k1, iv: k1);
    final k2 = _keyOfMd5('$secret$y');
    final g = _aesCbcDecryptUtf8(plaintext, key: k2, iv: k1);
    return _decodeBase64Loose(g);
  }

  /// 同 [deriveVpk], 直接返回 base64 密钥 — 供 `keyBase64` / `data:` URI 注入
  static String deriveVpkBase64({
    required String secret,
    required String rand,
    required String plaintext,
  }) {
    return base64.encode(deriveVpk(
      secret: secret,
      rand: rand,
      plaintext: plaintext,
    ));
  }

  // ─── 内部实现 ───

  /// `utf8(md5_hex(s)[8:24])` → 16 字节 AES 密钥
  static Uint8List _keyOfMd5(String s) {
    final hex = md5.convert(utf8.encode(s)).toString(); // 小写 hex, 32 字符
    return Uint8List.fromList(utf8.encode(hex.substring(8, 24)));
  }

  /// AES-128-CBC 解密 (站点口径): 入参 base64, 先剔除 \r\n, 宽松去填充后 UTF-8 解码
  static String _aesCbcDecryptUtf8(
    String base64Text, {
    required Uint8List key,
    required Uint8List iv,
  }) {
    final cleaned = base64Text.replaceAll(RegExp(r'[\r\n]'), '');
    final bytes = _decodeBase64Loose(cleaned);
    if (bytes.length < 16) return ''; // 密文太短, 无有效 CBC 块
    final encrypter = enc.Encrypter(enc.AES(
      enc.Key(key),
      mode: enc.AESMode.cbc,
      padding: null, // 自行去填充, 对齐 crypto-js 宽松策略
    ));
    final raw = Uint8List.fromList(
      encrypter.decryptBytes(enc.Encrypted(bytes), iv: enc.IV(iv)),
    );
    final unpadded = _stripPkcs7(raw);
    return utf8.decode(unpadded, allowMalformed: true);
  }

  /// 宽松 base64 解码 (crypto-js `Base64.parse` 口径)
  ///
  /// crypto-js 遇到非法字符直接丢弃、遇 `=` 提前结束, 且尾部不足一组的 bits
  /// 仍会被部分接受 —— 因此站点在密钥素材错配时不会抛异常, 而是得到垃圾字节。
  /// 本实现保持同样的不抛异常语义, 便于上层按"结果是否 16 字节"判断可用性。
  static Uint8List _decodeBase64Loose(String text) {
    var t = text.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
    final cut = t.indexOf('=');
    if (cut >= 0) t = t.substring(0, cut);
    if (t.isEmpty) return Uint8List(0);
    try {
      final padded = t + '=' * ((4 - t.length % 4) % 4);
      return Uint8List.fromList(base64.decode(padded));
    } catch (_) {
      final trim = t.length - (t.length % 4);
      if (trim <= 0) return Uint8List(0);
      try {
        return Uint8List.fromList(base64.decode(t.substring(0, trim)));
      } catch (_) {
        return Uint8List(0);
      }
    }
  }

  /// 去 PKCS7 填充 (crypto-js `pad.Pkcs7.unpad` 口径)
  ///
  /// crypto-js 只按末字节长度截断, 不校验每个填充字节; 长度越界时截断到 0。
  static Uint8List _stripPkcs7(Uint8List data) {
    if (data.isEmpty) return data;
    final pad = data[data.length - 1];
    if (pad < 1 || pad > data.length) return data;
    return Uint8List.sublistView(data, 0, data.length - pad);
  }

  /// 大端字节 → BigInt
  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  /// BigInt → 定长大端字节
  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}
