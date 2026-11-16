/// 认证仓库实现，编排登录/改密/短信/二维码等鉴权流程并组装 UserSession。
/// 对应 Python core/auth.py EWTAuthClient 的业务逻辑，短信发送前先取安全令牌（mode=1 需滑块验证）。
library;

import 'package:ewt_auto_client/core/captcha/captcha_models.dart';
import 'package:ewt_auto_client/core/constants/crypto_constants.dart';
import 'package:ewt_auto_client/core/crypto/crypto_utils.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:ewt_auto_client/features/auth/domain/repositories/auth_repository.dart';

/// 认证仓库实现
///
/// 对应 Python: core/auth.py EWTAuthClient 的业务编排逻辑
class AuthRepositoryImpl implements AuthRepository {
  final AuthRemoteDataSource _remote;
  final DioClient _client;

  AuthRepositoryImpl(this._remote, this._client);

  @override
  Future<UserSession> loginWithPassword({
    required String account,
    required String password,
    String? captchaToken,
  }) async {
    final data = await _remote.loginWithPassword(
      userName: account,
      password: password,
      captchaToken: captchaToken,
    );

    return _buildSession(data, account);
  }

  @override
  Future<({bool success, String? token, String? msg})> changePassword({
    required String oldPassword,
    required String newPassword,
    required String checkToken,
  }) =>
      _remote.changePassword(
        oldPassword: oldPassword,
        newPassword: newPassword,
        checkToken: checkToken,
      );

  @override
  Future<({bool success, String? msg})> changePasswordLoggedIn({
    required String oldPassword,
    required String newPassword,
  }) =>
      _remote.changePasswordLoggedIn(
        oldPassword: oldPassword,
        newPassword: newPassword,
      );

  @override
  Future<({String checkToken, bool existUser})> sendSmsCode(
    String phone, {
    String? captchaToken,
  }) async {
    // Step 1: 获取安全令牌
    final safe = await _remote.getSmsSafeToken(phone: phone);

    // mode 1 = 需要滑块验证
    if (safe.mode == 1) {
      throw const CaptchaRequiredException(failCode: '017129');
    }
    // mode 2 = 操作受限
    if (safe.mode == 2) {
      throw AuthException(safe.msg.isNotEmpty ? safe.msg : '操作受限，请稍后再试');
    }

    // Step 2: 发送短信 + 获取 checkToken
    return _remote.sendSmsByLogin(
      phone: phone,
      safeToken: safe.safeToken,
      captchaToken: captchaToken,
    );
  }

  @override
  Future<UserSession> loginWithSms({
    required String phone,
    required String smsCode,
    required String checkToken,
  }) async {
    // Step 3: 短信验证码登录
    final data = await _remote.loginWithSmsCode(
      phone: phone,
      smsCode: smsCode,
      checkToken: checkToken,
    );

    return _buildSession(data, phone);
  }

  @override
  Future<void> sendRegisterSmsCode(String phone, {String? captchaToken}) async {
    // Step 1: 获取安全令牌（注册 bizCode）
    final safe = await _remote.getSmsSafeToken(
      phone: phone,
      bizCode: CryptoConstants.registerSmsCaptchaBizCode,
    );

    // mode 1 = 需要滑块验证
    if (safe.mode == 1) {
      throw const CaptchaRequiredException(failCode: '017129');
    }
    // mode 2 = 操作受限
    if (safe.mode == 2) {
      throw AuthException(safe.msg.isNotEmpty ? safe.msg : '操作受限，请稍后再试');
    }

    // Step 2: 发送注册短信
    await _remote.sendRegisterSms(
      phone: phone,
      safeToken: safe.safeToken,
      captchaToken: captchaToken,
    );
  }

  @override
  Future<void> registerWithSms({
    required String phone,
    required String smsCode,
    required String password,
  }) async {
    // Step 3: 校验短信验证码 → authenticationToken
    final authenticationToken = await _remote.checkRegisterCode(
      phone: phone,
      smsCode: smsCode,
    );

    // Step 4: 创建账号（密码加密）
    final encryptedPassword = PasswordEncryptor.encrypt(password);
    await _remote.registerCreate(
      phone: phone,
      authenticationToken: authenticationToken,
      encryptedPassword: encryptedPassword,
      smsCode: smsCode,
    );
  }

  @override
  Future<UserSession> loginWithToken(String token) async {
    final parts = token.split('-');
    if (parts.length < 3) {
      throw const AuthException('Token 格式无效，应为: userId-platform-token');
    }

    // 先设置 token，确保后续请求携带认证信息
    _client.token = token;

    String userId = parts[0];
    String schoolId = '';
    String? account;
    String? displayName;
    String? avatar;
    String? schoolName;
    String? mobile;
    String? provinceCode;

    // validateToken (getUser) 可能返回非 JSON 或失败，仅作补充信息
    // getUser 响应字段: userName (账号, 对应首页"用户名") / nickName / avatar / mobile
    try {
      final data = await _remote.validateToken(token);
      account = data['account'] as String? ?? data['userName'] as String?;
      displayName = data['nickName'] as String?;
      avatar = data['avatar'] as String?;
      mobile = data['mobile'] as String?;
    } catch (_) {}

    try {
      final schoolInfo = await getSchoolUserInfo();
      userId = schoolInfo.userId;
      schoolId = schoolInfo.schoolId;
    } catch (_) {}

    // 获取 baseinfo (真名/头像/学校名/省份码/账号等完整字段)
    try {
      final baseInfo = await _remote.getBaseInfo();
      displayName = baseInfo['realName']?.toString() ?? displayName;
      avatar = baseInfo['photoUrl']?.toString() ??
          baseInfo['avatar']?.toString() ??
          avatar;
      schoolName = baseInfo['schoolName']?.toString();
      // 补全 validateToken 可能缺失的 account / mobile / provinceCode
      account = baseInfo['account']?.toString() ??
          baseInfo['userName']?.toString() ??
          account;
      mobile = baseInfo['mobile']?.toString() ?? mobile;
      provinceCode = baseInfo['memberProvinceCode']?.toString();
    } catch (_) {}

    return UserSession(
      token: token,
      userId: userId,
      schoolId: schoolId,
      account: account,
      displayName: displayName,
      avatar: avatar,
      schoolName: schoolName,
      provinceCode: provinceCode,
      mobile: mobile,
    );
  }

  @override
  Future<({String uuid, String qrcodeUrl})> generateQRCode() async {
    final data = await _remote.generateQRCode();
    return (
      uuid: data['uuid'] as String? ?? '',
      qrcodeUrl: data['qrcodeUrl'] as String? ?? '',
    );
  }

  @override
  Future<({int status, String? token})> checkQRCodeStatus(String uuid) async {
    final data = await _remote.checkQRCodeStatus(uuid);
    final status = data['status'] as int? ?? 1;

    // token 在 loginInfo.token 中
    final loginInfo = data['loginInfo'] as Map<String, dynamic>?;
    final token = loginInfo?['token'] as String? ?? data['token'] as String?;

    if (status == 4 && token != null && token.isNotEmpty) {
      _client.token = token;
    }

    return (status: status, token: token);
  }

  @override
  Future<void> logout() => _remote.logout();

  @override
  Future<({String userId, String schoolId})> getSchoolUserInfo() async {
    final data = await _remote.getSchoolUserInfo();
    return (
      userId: (data['userId'] ?? '').toString(),
      schoolId: (data['schoolId'] ?? '').toString(),
    );
  }

  @override
  Future<Map<String, dynamic>> getUserInfo() {
    return _remote.getBaseInfo();
  }

  /// 登录成功后构建完整会话（获取权威 userId/schoolId + 真名/头像/省份码）
  Future<UserSession> _buildSession(
    Map<String, dynamic> data,
    String account,
  ) async {
    final token = data['token'] as String? ?? '';
    var userId = (data['userId'] ?? '').toString();

    _client.token = token;

    String schoolId = '';
    String? displayName = data['nickName'] as String?;
    String? avatar = data['avatar'] as String?;
    String? schoolName;
    var mobile = data['mobile'] as String?;
    String? provinceCode;
    var resolvedAccount = data['account'] as String? ?? account;

    // 获取学校信息 (userId/schoolId)
    try {
      final schoolInfo = await getSchoolUserInfo();
      userId = schoolInfo.userId;
      schoolId = schoolInfo.schoolId;
    } catch (_) {}

    // 获取 baseinfo (真名/头像/学校名/省份码/账号等完整字段)
    try {
      final baseInfo = await _remote.getBaseInfo();
      displayName = baseInfo['realName']?.toString() ?? displayName;
      avatar = baseInfo['photoUrl']?.toString() ??
          baseInfo['avatar']?.toString() ??
          avatar;
      schoolName = baseInfo['schoolName']?.toString();
      // 补全登录响应可能缺失的 account / mobile / provinceCode
      resolvedAccount = baseInfo['account']?.toString() ??
          baseInfo['userName']?.toString() ??
          resolvedAccount;
      mobile = baseInfo['mobile']?.toString() ?? mobile;
      provinceCode = baseInfo['memberProvinceCode']?.toString();
    } catch (_) {}

    return UserSession(
      token: token,
      userId: userId,
      schoolId: schoolId,
      account: resolvedAccount,
      displayName: displayName,
      avatar: avatar,
      schoolName: schoolName,
      provinceCode: provinceCode,
      mobile: mobile,
    );
  }
}
