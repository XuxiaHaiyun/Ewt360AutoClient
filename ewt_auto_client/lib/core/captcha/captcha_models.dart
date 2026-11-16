/// 滑块验证码数据模型: 获取响应 CaptchaData、验证结果 CaptchaVerifyResult,
/// 以及风控触发异常 CaptchaRequiredException (响应码 017129/017130 等)。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 滑块验证数据模型
///
/// 对应 Python: core/captcha.py 中的数据结构

/// 获取验证码响应
class CaptchaData {
  final String sessionId;
  final Uint8List backgroundImage;
  final Uint8List pieceImage;
  final int pieceY;
  final String captchaToken;

  const CaptchaData({
    required this.sessionId,
    required this.backgroundImage,
    required this.pieceImage,
    required this.pieceY,
    required this.captchaToken,
  });

  factory CaptchaData.fromJson(Map<String, dynamic> json) {
    final extData = json['captchaExtData'] as String? ?? '{}';
    final ext = jsonDecode(extData) as Map<String, dynamic>;

    return CaptchaData(
      sessionId: json['captchaSessionId'] as String? ?? '',
      backgroundImage: base64Decode(
        _stripDataUri(json['captchaImgBase64'] as String? ?? ''),
      ),
      pieceImage: base64Decode(
        _stripDataUri(json['captchaExtImgBase64'] as String? ?? ''),
      ),
      pieceY: (ext['y'] as num?)?.toInt() ?? 0,
      captchaToken: json['captchaToken'] as String? ?? '',
    );
  }

  /// 去除 data URI 前缀
  ///
  /// 服务端返回格式: "data:image/jpg:base64,/9j/4AAQ..."
  /// 或 "data:image/png;base64,iVBOR..."
  static String _stripDataUri(String raw) {
    final idx = raw.indexOf('base64,');
    if (idx != -1) {
      return raw.substring(idx + 7);
    }
    return raw;
  }
}

/// 验证结果
class CaptchaVerifyResult {
  final bool success;
  final String captchaToken;

  const CaptchaVerifyResult({
    required this.success,
    required this.captchaToken,
  });

  factory CaptchaVerifyResult.fromJson(Map<String, dynamic> json) {
    return CaptchaVerifyResult(
      success: json['verifyResult'] == true,
      captchaToken: json['captchaToken'] as String? ?? '',
    );
  }
}

/// 风控异常 — 需要滑块验证
class CaptchaRequiredException implements Exception {
  final String failCode;
  final String message;

  const CaptchaRequiredException({
    required this.failCode,
    this.message = '需要完成滑块验证',
  });

  /// 判断响应码是否为风控触发
  static bool isRiskCode(String? code) {
    return code == '017129' || code == '017130' || code == '17129' || code == '17130';
  }

  @override
  String toString() => message;
}
