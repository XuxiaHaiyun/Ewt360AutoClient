/// 滑块验证码网络层: 直连 filegateway.ewt360.com 独立 Dio,
/// 提供获取验证码 (/captcha/get) 与校验滑块位置 (/captcha/verify) 接口, 无需 EWT 签名。
library;

import 'package:dio/dio.dart';

import '../constants/crypto_constants.dart';
import '../network/api_helper.dart';
import '../network/network_logger.dart';
import 'captcha_models.dart';

/// 滑块验证网络层
///
/// 对应 Python: core/captcha.py 中的 CaptchaClient
/// 端点: filegateway.ewt360.com（独立于主网关，无需 EWT 签名）
class CaptchaNet {
  static const String _baseUrl = 'https://filegateway.ewt360.com';
  static const String _getCaptchaPath = '/api/captcha/captcha/get';
  static const String _verifyCaptchaPath = '/api/captcha/captcha/verify';

  final String bizCode;
  final Dio _dio;

  CaptchaNet({
    this.bizCode = CryptoConstants.passwordCaptchaBizCode,
    Dio? dio,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json, text/plain, */*',
                ...ApiHeaders.www,
              },
            )) {
    // 内部创建的 Dio 纳入网络日志范围；外部传入的 Dio 由调用方决定
    if (dio == null) NetworkLogger.attach(_dio);
  }

  /// 获取滑块验证码
  ///
  /// POST /api/captcha/captcha/get
  /// body: {"bizCode": "...", "type": "2"}
  Future<CaptchaData> getCaptcha() async {
    final response = await _dio.post(
      '$_baseUrl$_getCaptchaPath',
      data: {
        'bizCode': bizCode,
        'type': '2',
      },
    );

    final json = response.data as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>?;

    if (data == null) {
      throw Exception('获取验证码失败: ${json['msg'] ?? '未知错误'}');
    }

    return CaptchaData.fromJson(data);
  }

  /// 验证滑块位置
  ///
  /// POST /api/captcha/captcha/verify
  /// body: {"bizCode":"...","type":"2","captchaSessionId":"...","verifyData":"[{\"x\":187,\"y\":67}]"}
  Future<CaptchaVerifyResult> verify({
    required String sessionId,
    required int x,
    required int y,
  }) async {
    final verifyData = '[{"x":$x,"y":$y}]';

    final response = await _dio.post(
      '$_baseUrl$_verifyCaptchaPath',
      data: {
        'bizCode': bizCode,
        'type': '2',
        'captchaSessionId': sessionId,
        'verifyData': verifyData,
      },
    );

    final json = response.data as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>?;

    if (data == null) {
      return const CaptchaVerifyResult(success: false, captchaToken: '');
    }

    return CaptchaVerifyResult.fromJson(data);
  }
}
