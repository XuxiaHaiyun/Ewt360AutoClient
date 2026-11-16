/// 风控配置加解密: 变种 Base64 + ChaCha20 (RFC 8439) + 8 轮 Feistel 差分,
/// 管线与 Python 端 generate_encrypted_config.py 逐字节一致 (Web 端 Feistel 有 53 位精度限制)。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'risk_control_constants.dart';

/// 变种 Base64: 标准 Base64 字符按 STD->CUS 字母表逐字符映射, padding '=' 不变。
class VariantBase64 {
  VariantBase64._();

  static final Map<int, int> _encMap = Map.fromIterables(
    RiskControlConstants.stdAlphabet.codeUnits,
    RiskControlConstants.customAlphabet.codeUnits,
  );
  static final Map<int, int> _decMap = Map.fromIterables(
    RiskControlConstants.customAlphabet.codeUnits,
    RiskControlConstants.stdAlphabet.codeUnits,
  );

  /// 字节 -> 变种 Base64 字符串
  static String encode(List<int> bytes) {
    final std = base64.encode(bytes);
    return String.fromCharCodes(std.codeUnits.map((c) => _encMap[c] ?? c));
  }

  /// 变种 Base64 字符串 -> 字节
  static Uint8List decode(String text) {
    final std = String.fromCharCodes(
      text.codeUnits.map((c) => _decMap[c] ?? c),
    );
    return base64.decode(std);
  }
}

/// ChaCha20 (RFC 8439) 原生实现。
///
/// 与 Python 端 `generate_encrypted_config.py` 的 `chacha20_block`/`chacha20_xor`
/// 逐字节一致, 用于风控配置核心流加密。
class ChaCha20 {
  ChaCha20._();

  static const int _rounds = 20;
  static const int _blockSize = 64;

  /// 用 256-bit key / 96-bit nonce 构造初始状态, counter 自 [initCounter] 起。
  static Uint8List _block(Uint8List key, Uint8List nonce, int initCounter) {
    const c0 = 0x61707865, c1 = 0x3320646e, c2 = 0x79622d32, c3 = 0x6b206574;
    final state = <int>[
      c0, c1, c2, c3,
      _le32(key, 0), _le32(key, 4), _le32(key, 8), _le32(key, 12),
      _le32(key, 16), _le32(key, 20), _le32(key, 24), _le32(key, 28),
      initCounter & 0xffffffff,
      _le32(nonce, 0), _le32(nonce, 4), _le32(nonce, 8),
    ];

    var x = List<int>.of(state);
    for (var i = 0; i < _rounds; i += 2) {
      x[0] = _qr(x[0], x[4], x[8], x[12]);
      x[1] = _qr(x[1], x[5], x[9], x[13]);
      x[2] = _qr(x[2], x[6], x[10], x[14]);
      x[3] = _qr(x[3], x[7], x[11], x[15]);
      x[0] = _qr(x[0], x[5], x[10], x[15]);
      x[1] = _qr(x[1], x[6], x[11], x[12]);
      x[2] = _qr(x[2], x[7], x[8], x[13]);
      x[3] = _qr(x[3], x[4], x[9], x[14]);
    }
    for (var i = 0; i < 16; i++) {
      x[i] = (x[i] + state[i]) & 0xffffffff;
    }

    final out = Uint8List(_blockSize);
    for (var i = 0; i < 16; i++) {
      out[_b4(i)] = _be32Bytes(x[i], 0);
      out[_b4(i) + 1] = _be32Bytes(x[i], 1);
      out[_b4(i) + 2] = _be32Bytes(x[i], 2);
      out[_b4(i) + 3] = _be32Bytes(x[i], 3);
    }
    return out;
  }

  static int _qr(int a, int b, int c, int d) {
    a = (a + b) & 0xffffffff;
    d = _rotl32(d ^ a, 16);
    c = (c + d) & 0xffffffff;
    b = _rotl32(b ^ c, 12);
    a = (a + b) & 0xffffffff;
    d = _rotl32(d ^ a, 8);
    c = (c + d) & 0xffffffff;
    b = _rotl32(b ^ c, 7);
    return a;
  }

  static int _rotl32(int x, int n) {
    if (n == 0) return x & 0xffffffff;
    return ((x << n) | (x >> (32 - n))) & 0xffffffff;
  }

  static int _le32(Uint8List arr, int off) =>
      arr[off] | (arr[off + 1] << 8) | (arr[off + 2] << 16) |
      (arr[off + 3] << 24);

  static int _b4(int i) => i * 4;

  static int _be32Bytes(int v, int byte) => (v >> ((3 - byte) * 8)) & 0xff;

  /// 生成 keystream 并与 [data] 逐字节异或 (就地长度同步流)。
  static Uint8List apply(
    Uint8List data,
    Uint8List key,
    Uint8List nonce,
    int initCounter,
  ) {
    final out = Uint8List(data.length);
    var counter = initCounter;
    for (var off = 0; off < data.length; off += _blockSize) {
      final ks = _block(key, nonce, counter++);
      final n = (data.length - off) < _blockSize
          ? (data.length - off)
          : _blockSize;
      for (var i = 0; i < n; i++) {
        out[off + i] = data[off + i] ^ ks[i];
      }
    }
    return out;
  }
}

/// 字节级"旋转-异或"32 位整型缩放 (与 Python `_ror`/`_rol` 一致)。
///
/// 注意: 64 位运算依赖 VM 的精确 64 位整数; Web (JS number) 仅 53 位精确,
/// Feistel 层在 Web 端可能结果不一致 (Web 端如需启用需改 BigInt 实现)。
class BitOps {
  BitOps._();

  static int rotl64(int x, int n) {
    final m = 64;
    n &= m - 1;
    // n == 0 时原实现为 x & 0xffffffffffffffff (全 1 掩码 = 恒等);
    // 该 64 位字面量在 Web (JS) 下无法精确表示导致编译失败, 直接返回 x。
    if (n == 0) return x;
    // 注意: [x] 可能为负数(_be64 读出的 64 位值在最高位为 1 时为有符号负值),
    // 右移必须用零填充的 `>>>`, 否则算术 `>>` 会符号扩展导致与 Python 端不一致。
    return ((x << n) | (x >>> (m - n)));
  }

  static int rotr64(int x, int n) => rotl64(x, 64 - (n & 63));
}

/// 风控配置加密/解密
///
/// 管线 (与 Python 端 `RiskControl/generate_encrypted_config.py` 逐字节一致):
///   UTF-8 -> PKCS7(块16) -> ChaCha20(RFC8439, 20轮) 流加密
///        -> 8轮 Feistel 差分(块16, 子钥=sha256(派生钥+轮次))
///        -> 字节反序 -> 变种Base64 -> 标记包裹
///
/// KDF (派生三类子钥):
///   master = sha256(seed)
///   chaChaKey  = sha256(master + '::K1::')   (32B)
///   chaChaNnc  = sha256(master + '::N1::')[:12]  (12B)
///   feistelKey = sha256(master + '::F1::')   (32B)
class RiskControlCrypto {
  RiskControlCrypto._();

  static const int _padBlock = 16;
  static const int _feistelRounds = 8;

  /// 派生子钥三元组 (key, nonce, feistelKey)
  static (Uint8List, Uint8List, Uint8List) _deriveKeys() {
    final master =
        sha256.convert(utf8.encode(RiskControlConstants.aesSeed)).bytes;
    final chaChaKey = sha256
        .convert([...master, ...utf8.encode('::K1::')])
        .bytes;
    final nonce = sha256
        .convert([...master, ...utf8.encode('::N1::')])
        .bytes
        .sublist(0, 12);
    final feistelKey = sha256
        .convert([...master, ...utf8.encode('::F1::')])
        .bytes;
    return (
      Uint8List.fromList(chaChaKey),
      Uint8List.fromList(nonce),
      Uint8List.fromList(feistelKey),
    );
  }

  /// Feistel 单轮子钥: sha256(feistelKey + 轮次字节) 前 8 字节
  static Uint8List _subKey(Uint8List feistelKey, int round) {
    final r = utf8.encode('R$round');
    final h = sha256.convert([...feistelKey, ...r]).bytes;
    return Uint8List.fromList(h.sublist(0, 8));
  }

  /// 8 字节大端 -> 64 位整数
  ///
  /// 末尾的全 1 掩码 (原 0xffffffffffffffff) 为恒等运算, 已省略
  /// (该 64 位字面量在 Web (JS) 下无法精确表示导致编译失败)。
  static int _be64(Uint8List b, int off) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | (b[off + i] & 0xff);
    }
    return v;
  }

  static Uint8List _fromBe64(int v) {
    final out = Uint8List(8);
    for (var i = 7; i >= 0; i--) {
      out[i] = v & 0xff;
      v >>= 8;
    }
    return out;
  }

  /// Feistel 前向: 块16 (L=前8, R=后8), 8 轮。
  static Uint8List _feistelEncrypt(
    Uint8List data,
    Uint8List feistelKey,
  ) {
    final out = Uint8List(data.length);
    for (var blk = 0; blk < data.length; blk += _padBlock) {
      var L = _be64(data, blk);
      var R = _be64(data, blk + 8);
      for (var r = 0; r < _feistelRounds; r++) {
        final sub = _reinterpret(_subKey(feistelKey, r));
        final f = BitOps.rotl64(R, (r + 1) * 3) ^ sub;
        final newL = R;
        final newR = L ^ f;
        L = newL;
        R = newR;
      }
      final lo = _fromBe64(L);
      final hi = _fromBe64(R);
      out.setRange(blk, blk + 8, lo);
      out.setRange(blk + 8, blk + 16, hi);
    }
    return out;
  }

  /// Feistel 反向: 逆序轮次还原。
  static Uint8List _feistelDecrypt(
    Uint8List data,
    Uint8List feistelKey,
  ) {
    final out = Uint8List(data.length);
    for (var blk = 0; blk < data.length; blk += _padBlock) {
      var L = _be64(data, blk);
      var R = _be64(data, blk + 8);
      for (var r = _feistelRounds - 1; r >= 0; r--) {
        final sub = _reinterpret(_subKey(feistelKey, r));
        // 逆: oldR = L; oldL = R ^ rotl(oldR,..)  (等价 R 变换对称)
        final oldR = L;
        final oldL = R ^ BitOps.rotl64(oldR, (r + 1) * 3) ^ sub;
        L = oldL;
        R = oldR;
      }
      final lo = _fromBe64(L);
      final hi = _fromBe64(R);
      out.setRange(blk, blk + 8, lo);
      out.setRange(blk + 8, blk + 16, hi);
    }
    return out;
  }

  /// 8 字节子钥 -> 64 位整数 (与 Python 端一致: 大端读取)
  static int _reinterpret(Uint8List b) => _be64(b, 0);

  /// PKCS7 填充到块大小的倍数
  static Uint8List _pad(List<int> raw, int block) {
    final padLen = block - (raw.length % block);
    final out = Uint8List(raw.length + padLen);
    out.setRange(0, raw.length, raw);
    for (var i = raw.length; i < out.length; i++) {
      out[i] = padLen;
    }
    return out;
  }

  static List<int> _unpad(List<int> padded, int block) {
    if (padded.isEmpty) return const [];
    final padLen = padded.last;
    if (padLen <= 0 || padLen > block) return padded;
    return padded.sublist(0, padded.length - padLen);
  }

  /// 加密 JSON 字符串 -> 带首尾标记的密文
  static String encrypt(String jsonStr) {
    final (key, nonce, feistelKey) = _deriveKeys();
    final raw = _pad(utf8.encode(jsonStr), _padBlock);
    final ct = ChaCha20.apply(raw, key, nonce, 0);
    final mixed = _feistelEncrypt(ct, feistelKey);
    final rev = Uint8List.fromList(mixed.reversed.toList());
    final b64 = VariantBase64.encode(rev);
    return '${RiskControlConstants.configMarker}\n$b64\n${RiskControlConstants.configMarker}';
  }

  /// 解密 payload -> JSON 字符串
  ///
  /// [payload] 可为: 含首尾标记的完整文本 / 仅变种 Base64 / 含多余空白。
  static String decrypt(String payload) {
    final marker = RiskControlConstants.configMarker;
    final pattern =
        RegExp('${RegExp.escape(marker)}([\\s\\S]*?)${RegExp.escape(marker)}');
    final match = pattern.firstMatch(payload);
    final raw = (match?.group(1) ?? payload).replaceAll(RegExp(r'\s'), '');

    final (key, nonce, feistelKey) = _deriveKeys();
    final rev = VariantBase64.decode(raw);
    final mixed = Uint8List.fromList(rev.reversed.toList());
    final ct = _feistelDecrypt(mixed, feistelKey);
    final plain = ChaCha20.apply(ct, key, nonce, 0);
    return utf8.decode(_unpad(plain, _padBlock));
  }
}