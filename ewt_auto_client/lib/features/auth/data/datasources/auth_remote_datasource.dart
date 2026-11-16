/// 认证远程数据源，封装密码/短信登录、checkToken 改密、注册等鉴权 API。
/// 密码经 AES-256-CBC 加密提交；风控码抛 CaptchaRequiredException，需改密抛 PasswordChangeRequiredException。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ewt_auto_client/core/captcha/captcha_models.dart';
import 'package:ewt_auto_client/core/constants/api_constants.dart';
import 'package:ewt_auto_client/core/constants/crypto_constants.dart';
import 'package:ewt_auto_client/core/crypto/crypto_utils.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/auth/domain/auth_exceptions.dart';

/// 认证远程数据源
///
/// 对应 Python: core/auth.py 中的所有 API 调用
class AuthRemoteDataSource {
  final DioClient _client;

  AuthRemoteDataSource(this._client);

  /// 密码登录
  ///
  /// POST /api/authcenter/v2/oauth/login/account
  /// Python payload: userName, password, autoLogin, webVersion, platform(int)
  /// [password] 为明文密码（内部使用 AES-256-CBC 加密后提交）
  /// [captchaToken] 滑块验证通过后附加的令牌
  ///
  /// 特殊响应处理：
  ///   - 风控码 (017129/017130) → 抛 [CaptchaRequiredException]
  ///   - 登录"成功"且 data.failCode 需改密 (017179/017180/017442 + checkToken)
  ///     → 抛 [PasswordChangeRequiredException]
  ///   - 其余失败（017133 密码错误 / 017126 / 017421 等）→ 抛 [AuthException]
  Future<Map<String, dynamic>> loginWithPassword({
    required String userName,
    required String password,
    bool autoLogin = true,
    int platform = 1,
    String? captchaToken,
  }) async {
    final payload = <String, dynamic>{
      'userName': userName,
      'password': PasswordEncryptor.encrypt(password),
      'autoLogin': autoLogin,
      'webVersion': 'pc_20250101',
      'platform': platform,
    };
    if (captchaToken != null && captchaToken.isNotEmpty) {
      payload['captchaToken'] = captchaToken;
    }

    final response = await _client.post(ApiConstants.loginUrl, data: payload);

    if (!response.isSuccess) {
      _checkRiskCode(response);
      // 弱密码 / 需改密：弹窗改密后重登
      final pwdEx = _resolvePasswordChange(response, userName, password);
      if (pwdEx != null) throw pwdEx;
      throw AuthException(response.msg, code: response.code);
    }

    // 登录"成功"但仍可能要求改密（web: data.status==2 + checkToken）
    final pwdExSuccess = _resolvePasswordChange(response, userName, password);
    if (pwdExSuccess != null) throw pwdExSuccess;

    return response.data as Map<String, dynamic>;
  }

  /// 从登录响应中识别"需改密"类响应，命中则返回异常（含改密所需的 checkToken）
  PasswordChangeRequiredException? _resolvePasswordChange(
    ApiResponse response,
    String userName,
    String password,
  ) {
    final data = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : null;
    final failCodeRaw = data?['failCode'] ?? data?['captchaFailCode'];
    final failCode = failCodeRaw?.toString();

    final required = LoginErrorClassifier.isPasswordChangeRequired(
      code: response.code,
      failCode: failCode,
      msg: response.msg,
      isSuccess: response.isSuccess,
      data: data,
    );
    if (!required) return null;

    final checkToken = LoginErrorClassifier.extractCheckToken(data);
    final message = response.msg.isNotEmpty
        ? response.msg
        : '当前密码过于简单，为了账号安全，请修改密码';
    return PasswordChangeRequiredException(
      account: userName,
      oldPassword: password,
      checkToken: checkToken,
      message: message,
      failCode: failCode ?? response.code,
    );
  }

  /// 改密（弱密码等登录拦截场景）
  ///
  /// 对齐 web `ewtLogin` chunk：两个候选端点 body 字段完全一致
  /// （password / newPassword / validatePassword 均 AES 加密，附加 checkToken）。
  /// 依次尝试手机型与账号型端点，任一成功即返回（成功响应可能直接带 `token`）。
  /// 注意：body 必须携带 `platform`（网关按 body 校验平台参数，缺失报
  /// "平台类型不能为空"，实测 2026-08-24）。
  Future<({bool success, String? token, String? msg})> changePassword({
    required String oldPassword,
    required String newPassword,
    required String checkToken,
  }) async {
    final body = <String, dynamic>{
      'platform': 1,
      'password': PasswordEncryptor.encrypt(oldPassword),
      'newPassword': PasswordEncryptor.encrypt(newPassword),
      'validatePassword': PasswordEncryptor.encrypt(newPassword),
      'checkToken': checkToken,
    };

    String? lastMsg;
    for (final url in [
      ApiConstants.changePasswordMobileUrl,
      ApiConstants.changePasswordAccountUrl,
    ]) {
      try {
        final response = await _client.post(url, data: body);
        if (response.isSuccess) {
          final data = response.data is Map<String, dynamic>
              ? response.data as Map<String, dynamic>
              : null;
          final token = data?['token'] as String?;
          return (success: true, token: token, msg: response.msg);
        }
        lastMsg = response.msg;
      } on ApiException catch (e) {
        // 网络/解析层异常：尝试下一个端点
        lastMsg = e.message;
      }
    }
    return (success: false, token: null, msg: lastMsg ?? '修改密码失败');
  }

  /// 账号中心主动改密（已登录状态，用旧密码改密）
  ///
  /// 对齐 web `member-center` SPA `ChangePassword/service`:
  ///   POST /api/usercenter/user/operate/change/password
  /// body: { platform, oldPassword, newPassword } (密码均 AES 加密，与登录加密一致)
  /// 鉴权靠已登录 session token（DioClient.token 已设置），无需 checkToken。
  /// 修改成功后旧 token 通常失效，调用方应重新登录刷新会话。
  Future<({bool success, String? msg})> changePasswordLoggedIn({
    required String oldPassword,
    required String newPassword,
  }) async {
    final body = <String, dynamic>{
      'platform': 1,
      'oldPassword': PasswordEncryptor.encrypt(oldPassword),
      'newPassword': PasswordEncryptor.encrypt(newPassword),
    };
    try {
      final response = await _client.post(
        ApiConstants.changePasswordLoggedInUrl,
        data: body,
      );
      if (response.isSuccess) {
        return (success: true, msg: response.msg);
      }
      return (success: false, msg: response.msg);
    } on ApiException catch (e) {
      return (success: false, msg: e.message);
    }
  }

  // ─── 短信登录（3 步流程） ───

  /// Step 1: 获取安全令牌
  ///
  /// POST /api/safecenter/business/control/type
  /// 返回 safeToken + mode (0=无需验证, 1=需要滑块, 2=受限)
  ///
  /// [bizCode] 默认使用短信登录 bizCode，注册时传入 [CryptoConstants.registerSmsCaptchaBizCode]
  Future<({String safeToken, int mode, String msg})> getSmsSafeToken({
    required String phone,
    String? bizCode,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final code = bizCode ?? CryptoConstants.smsCaptchaBizCode;
    final checkSign = _generateCheckSign(code, phone, timestamp);

    final response = await _client.post(
      ApiConstants.safecenterControlTypeUrl,
      data: {
        'bizCode': code,
        'type': '2',
        'mobile': phone,
        'timestamp': timestamp,
        'checkSign': checkSign,
      },
    );

    if (!response.isSuccess) {
      throw AuthException(response.msg, code: response.code);
    }

    final data = response.data as Map<String, dynamic>? ?? {};
    return (
      safeToken: data['token'] as String? ?? '',
      mode: (data['mode'] as num?)?.toInt() ?? 0,
      msg: data['msg'] as String? ?? '',
    );
  }

  // ─── 短信注册（4 步流程，与短信登录同构） ───

  /// Step 2: 发送注册短信验证码
  ///
  /// POST /api/usercenter/sms/send/verification/code/safecenter
  /// body: { mobile, safeToken, messageType: 1 }（+ 可选 captchaToken）
  Future<void> sendRegisterSms({
    required String phone,
    required String safeToken,
    String? captchaToken,
  }) async {
    final body = <String, dynamic>{
      'mobile': phone,
      'safeToken': safeToken,
      'messageType': 1,
    };
    if (captchaToken != null && captchaToken.isNotEmpty) {
      body['captchaToken'] = captchaToken;
    }

    final response = await _client.post(
      ApiConstants.registerSmsSendUrl,
      data: body,
      headers: {'token': '0', 'referurl': 'https://www.ewt360.com/'},
    );

    if (!response.isSuccess) {
      throw AuthException(response.msg, code: response.code);
    }
  }

  /// Step 3: 校验短信验证码，返回 authenticationToken
  ///
  /// POST /api/usercenter/register/check/code/
  /// 成功时 data.authenticationToken 用于 Step 4 创建账号
  Future<String> checkRegisterCode({
    required String phone,
    required String smsCode,
  }) async {
    final response = await _client.post(
      ApiConstants.registerCheckCodeUrl,
      data: {
        'mobile': phone,
        'smsCode': smsCode,
      },
    );

    if (!response.isSuccess) {
      throw AuthException(response.msg, code: response.code);
    }

    final data = response.data as Map<String, dynamic>? ?? {};
    final token = (data['authenticationToken'] ?? data['token']) as String? ?? '';
    if (token.isEmpty) {
      throw AuthException('验证码校验失败：未返回令牌');
    }
    return token;
  }

  /// Step 4: 创建账号
  ///
  /// POST /api/usercenter/register/mobile
  /// [authenticationToken] 来自 [checkRegisterCode]
  /// [encryptedPassword] 为 AES-256-CBC 加密后的密码（见 [PasswordEncryptor]）
  ///
  /// 注：create 端点位于 web 注册页懒加载 chunk 中，字段依据 web 注册流程推断
  /// （mobile + authenticationToken + password）。如服务端校验失败请按需追加字段。
  Future<void> registerCreate({
    required String phone,
    required String authenticationToken,
    required String encryptedPassword,
    String? smsCode,
  }) async {
    final body = <String, dynamic>{
      'mobile': phone,
      'authenticationToken': authenticationToken,
      'password': encryptedPassword,
    };
    if (smsCode != null && smsCode.isNotEmpty) {
      body['smsCode'] = smsCode;
    }

    final response = await _client.post(
      ApiConstants.registerCreateUrl,
      data: body,
    );

    if (!response.isSuccess) {
      throw AuthException(response.msg, code: response.code);
    }
  }

  /// Step 2: 发送短信验证码 + 获取 checkToken
  ///
  /// POST /api/usercenter/user/login/sms/byLogin/safecenter
  Future<({String checkToken, bool existUser})> sendSmsByLogin({
    required String phone,
    required String safeToken,
    String? captchaToken,
  }) async {
    final body = <String, dynamic>{
      'platform': 1,
      'mobile': phone,
      'safeToken': safeToken,
    };
    if (captchaToken != null && captchaToken.isNotEmpty) {
      body['captchaToken'] = captchaToken;
    }

    final response = await _client.post(
      ApiConstants.smsLoginSafecenterUrl,
      data: body,
      headers: {'token': '0', 'referurl': 'https://www.ewt360.com/'},
    );

    if (!response.isSuccess) {
      throw AuthException(response.msg, code: response.code);
    }

    final data = response.data as Map<String, dynamic>? ?? {};
    return (
      checkToken: data['checkToken'] as String? ?? '',
      existUser: data['existUser'] == true,
    );
  }

  /// Step 3: 短信验证码登录
  ///
  /// POST /api/usercenter/user/login/mobile/login
  Future<Map<String, dynamic>> loginWithSmsCode({
    required String phone,
    required String smsCode,
    required String checkToken,
  }) async {
    final response = await _client.post(
      ApiConstants.smsLoginMobileUrl,
      data: {
        'platform': 1,
        'mobile': phone,
        'smsCode': smsCode,
        'autoLogin': true,
        'checkToken': checkToken,
      },
      headers: {'token': '0', 'referurl': 'https://www.ewt360.com/'},
    );

    if (!response.isSuccess) {
      throw AuthException(response.msg, code: response.code);
    }
    return response.data as Map<String, dynamic>;
  }

  /// 生成 safecenter checkSign
  ///
  /// 算法: MD5(secret + bizCode + mobile + timestamp + secret)
  /// secret = "eo^nye1j#!wt2%v)"
  String _generateCheckSign(String bizCode, String mobile, int timestamp) {
    const secret = CryptoConstants.dlogSignKey;
    final input = '$secret$bizCode$mobile$timestamp$secret';
    return md5.convert(utf8.encode(input)).toString();
  }

  /// Token 验证登录
  ///
  /// GET /api/usercenter/user/login/getUser
  /// 注意: 调用方需提前设置 _client.token
  Future<Map<String, dynamic>> validateToken(String token) async {
    final response = await _client.get(ApiConstants.userInfoUrl);

    if (!response.isSuccess) {
      throw AuthException('Token 验证失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 生成二维码
  ///
  /// POST /api/authcenter/v2/oauth/login/qrcode/generate
  Future<Map<String, dynamic>> generateQRCode() async {
    final response = await _client.post(
      ApiConstants.qrcodeGenerateUrl,
      data: {'source': 'pc'},
    );

    if (!response.isSuccess) {
      throw AuthException('二维码生成失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 查询二维码状态
  ///
  /// POST /api/authcenter/v2/oauth/login/qrcode/status
  Future<Map<String, dynamic>> checkQRCodeStatus(String uuid) async {
    final response = await _client.post(
      ApiConstants.qrcodeStatusUrl,
      data: {'uuid': uuid},
    );

    if (!response.isSuccess) {
      throw AuthException('二维码状态查询失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 获取学校用户信息
  ///
  /// GET /api/eteacherproduct/school/getSchoolUserInfo
  Future<Map<String, dynamic>> getSchoolUserInfo() async {
    final response = await _client.get(ApiConstants.schoolUserInfoUrl);

    if (!response.isSuccess) {
      throw AuthException('获取学校信息失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 获取用户基本信息
  ///
  /// GET /api/usercenter/user/baseinfo
  Future<Map<String, dynamic>> getBaseInfo() async {
    final response = await _client.get(ApiConstants.baseInfoUrl);

    if (!response.isSuccess) {
      throw AuthException('获取基本信息失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 登出
  ///
  /// POST /api/authcenter/oauth/logout
  /// body: {"platform": 1, "token": "..."}
  Future<void> logout() async {
    final token = _client.token ?? '';
    await _client.post(
      ApiConstants.logoutUrl,
      data: {'platform': 1, 'token': token},
    );
    _client.token = null;
  }

  /// 检测响应中的风控码，触发滑块验证异常
  ///
  /// Python: data.failCode / data.captchaFailCode == "017129"/"017130"
  /// 或顶层 code == 17129/17130
  void _checkRiskCode(ApiResponse response) {
    // 检查顶层 code
    if (CaptchaRequiredException.isRiskCode(response.code)) {
      throw CaptchaRequiredException(failCode: response.code);
    }

    // 检查 data 内的 failCode / captchaFailCode
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final failCode = (data['failCode'] ?? data['captchaFailCode'])?.toString();
      if (CaptchaRequiredException.isRiskCode(failCode)) {
        throw CaptchaRequiredException(failCode: failCode!);
      }
    }
  }
}
