/// 加解密/签名工具集: AES-256-CBC 密码加密、MD5 请求签名、
/// BFE 遥测 HMAC-SHA1 签名与 DLOG MD5 签名, 对应 Python encryptor.py/player.py。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

import '../constants/crypto_constants.dart';

/// AES-256-CBC 密码加密器
///
/// 对应 Python: core/encryptor.py EWTPasswordEncryptor
class PasswordEncryptor {
  PasswordEncryptor._();

  static final _key = enc.Key(Uint8List.fromList(
    utf8.encode(CryptoConstants.aesKey),
  ));
  static final _iv = enc.IV(Uint8List.fromList(
    utf8.encode(CryptoConstants.aesIv),
  ));

  /// 加密密码，返回大写十六进制字符串
  ///
  /// 算法: AES-256-CBC + PKCS7 填充 → 大写 hex
  static String encrypt(String password) {
    final encrypter = enc.Encrypter(
      enc.AES(_key, mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    final encrypted = encrypter.encrypt(password, iv: _iv);
    return encrypted.base16.toUpperCase();
  }
}

/// 请求签名工具
///
/// 对应 Python: utils.py generate_sign / generate_timestamp
class RequestSigner {
  RequestSigner._();

  /// 生成当前时间戳（毫秒）
  static int generateTimestamp() => DateTime.now().millisecondsSinceEpoch;

  /// 生成请求签名: MD5(timestamp + secretKey).toUpperCase()
  static String generateSign(int timestamp, String secretKey) {
    final input = '$timestamp$secretKey';
    final digest = md5.convert(utf8.encode(input));
    return digest.toString().toUpperCase();
  }
}

/// BFE/CLOG collect/batch 遥测签名 (HMAC-SHA1)
///
/// 对应 Python: core/player.py `_sign_bfe_hmac_sha1`
///
/// 签名串按字段名字典序拼接:
/// `action={action}&duration={stayTime}&mstid={token}&signatureMethod=HMAC-SHA1`
/// `&signatureVersion=1.0&timestamp={reportTime}&version=2022-08-02`
///
/// 密钥为 getPlayerGlobalConf 返回的 `globalInfo.secret`，输出 40 位小写 hex。
class BfeSigner {
  BfeSigner._();

  static String signCollect({
    required String secret,
    required String token,
    required int action,
    required int duration,
    required int timestamp,
  }) {
    final sigStr = 'action=$action&duration=$duration&mstid=$token'
        '&signatureMethod=HMAC-SHA1&signatureVersion=1.0'
        '&timestamp=$timestamp&version=2022-08-02';
    final hmac = Hmac(sha1, utf8.encode(secret));
    final digest = hmac.convert(utf8.encode(sigStr));
    return digest.toString();
  }
}

/// DLOG 签名 (MD5)
///
/// 对应 Python: core/player.py `_sign_dlog_md5`
/// 签名串: `log={JSON 字符串}&key={secret}`，输出 32 位 hex。
class DlogSigner {
  DlogSigner._();

  static String sign(String logJson) {
    final input = 'log=$logJson&key=${CryptoConstants.dlogSignKey}';
    final digest = md5.convert(utf8.encode(input));
    return digest.toString();
  }
}
