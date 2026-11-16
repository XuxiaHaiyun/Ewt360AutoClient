/// 认证仓库抽象接口：密码/短信/二维码/Token 登录、改密、注册、登出等鉴权操作契约。
/// 弱密码/需改密场景抛 PasswordChangeRequiredException，需滑块验证抛 CaptchaRequiredException。
library;

import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';

/// 认证仓库抽象接口
abstract class AuthRepository {
  /// 密码登录
  ///
  /// [captchaToken] 滑块验证通过后附加
  /// 若登录响应为弱密码 / 需改密类，抛出 [PasswordChangeRequiredException]
  Future<UserSession> loginWithPassword({
    required String account,
    required String password,
    String? captchaToken,
  });

  /// 改密（弱密码等登录拦截场景）
  ///
  /// [oldPassword] 原密码（明文），[newPassword] 新密码（明文），
  /// [checkToken] 来自需改密登录响应的 checkToken。
  /// 返回是否成功、成功时可能携带的 token、以及服务端消息。
  Future<({bool success, String? token, String? msg})> changePassword({
    required String oldPassword,
    required String newPassword,
    required String checkToken,
  });

  /// 账号中心主动改密（已登录状态，用旧密码改密）
  ///
  /// [oldPassword] 原密码（明文），[newPassword] 新密码（明文）。
  /// 鉴权靠已登录 session token，无需 checkToken。
  /// 返回是否成功及服务端消息。
  Future<({bool success, String? msg})> changePasswordLoggedIn({
    required String oldPassword,
    required String newPassword,
  });

  /// 发送短信验证码（safecenter → byLogin/safecenter）
  ///
  /// 返回 checkToken（登录时需要）和 existUser（是否已注册）
  /// 如果需要滑块验证，抛出 CaptchaRequiredException
  Future<({String checkToken, bool existUser})> sendSmsCode(
    String phone, {
    String? captchaToken,
  });

  /// 短信验证码登录（mobile/login）
  Future<UserSession> loginWithSms({
    required String phone,
    required String smsCode,
    required String checkToken,
  });

  /// 发送注册短信验证码（safecenter → send）
  ///
  /// 如需滑块验证抛出 CaptchaRequiredException；成功返回 void
  Future<void> sendRegisterSmsCode(String phone, {String? captchaToken});

  /// 短信注册：校验验证码并创建账号
  ///
  /// [password] 明文密码（内部使用 AES-256-CBC 加密后提交）
  /// 成功返回 void
  Future<void> registerWithSms({
    required String phone,
    required String smsCode,
    required String password,
  });

  /// Token 登录
  Future<UserSession> loginWithToken(String token);

  /// 生成二维码登录
  Future<({String uuid, String qrcodeUrl})> generateQRCode();

  /// 轮询二维码状态
  /// 状态: 1=等待, 2=已扫码, 3=过期, 4=已确认, 5=已取消
  Future<({int status, String? token})> checkQRCodeStatus(String uuid);

  /// 登出
  Future<void> logout();

  /// 获取学校用户信息
  Future<({String userId, String schoolId})> getSchoolUserInfo();

  /// 获取用户基本信息
  Future<Map<String, dynamic>> getUserInfo();
}
