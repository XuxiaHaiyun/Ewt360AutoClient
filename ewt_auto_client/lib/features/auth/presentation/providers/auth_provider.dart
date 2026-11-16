/// 认证状态管理与 Riverpod Provider：登录（密码/短信/二维码/Token）、登出及持久化会话恢复。
/// 状态为 sealed class，含需滑块验证（AuthCaptchaRequired）与需改密（AuthPasswordChangeRequired）专用分支。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ewt_auto_client/core/captcha/captcha_models.dart';
import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/account_storage.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/session_store.dart';
import 'package:ewt_auto_client/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:ewt_auto_client/features/auth/domain/auth_exceptions.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:ewt_auto_client/features/auth/domain/repositories/auth_repository.dart';

// ─── Providers ───

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final client = getIt<DioClient>();
  final remote = AuthRemoteDataSource(client);
  return AuthRepositoryImpl(remote, client);
});

/// 认证状态
sealed class AuthState {
  const AuthState();
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthAuthenticated extends AuthState {
  final UserSession session;
  const AuthAuthenticated(this.session);
}

class AuthError extends AuthState {
  final String message;
  const AuthError(this.message);
}

/// 需要滑块验证
class AuthCaptchaRequired extends AuthState {
  /// 原始登录方式: 'password' | 'sms'
  final String loginMethod;
  final String account;
  final String credential;

  const AuthCaptchaRequired({
    required this.loginMethod,
    required this.account,
    required this.credential,
  });
}

/// 需要修改密码（弱密码等）
///
/// 登录响应命中"需改密"类时进入此状态，UI 据此弹出改密弹窗，
/// 改密成功后再用新密码重新登录。
class AuthPasswordChangeRequired extends AuthState {
  final String account;
  final String oldPassword;
  final String? checkToken;
  final String message;

  const AuthPasswordChangeRequired({
    required this.account,
    required this.oldPassword,
    this.checkToken,
    required this.message,
  });
}

/// 认证状态管理器
class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;

  /// 会话持久化 (数据层, 独立于 UI)
  final SessionStore _sessionStore = const SessionStore();

  /// 短信登录流程中暂存的 checkToken（sendSmsCode → loginWithSms）
  String? _smsCheckToken;

  AuthNotifier(this._repository) : super(const AuthInitial());

  // ─── 会话持久化 ───

  /// 持久化会话并同步代理到全局 DioClient, 返回实际生效的会话
  ///
  /// 登录路径 ([inheritStoredProxy] = true) 且新会话未携带代理时, 继承已
  /// 保存同账号条目的代理: 列表单击登录/重登后当前会话沿用该账号已配置的
  /// 代理, 与批量任务按账号走独立代理的行为一致。
  Future<UserSession> _persistSession(
    UserSession session, {
    bool inheritStoredProxy = true,
  }) async {
    var effective = session;
    if (inheritStoredProxy && (session.proxy ?? '').trim().isEmpty) {
      try {
        final accounts = await AccountStorage.loadAccounts();
        for (final a in accounts) {
          if (a.isSameAccount(session) && (a.proxy ?? '').trim().isNotEmpty) {
            effective = session.withProxy(a.proxy);
            break;
          }
        }
      } catch (_) {}
    }
    if (getIt.isRegistered<DioClient>()) {
      getIt<DioClient>().updateProxy(effective.proxy);
    }
    await _sessionStore.save(effective);
    return effective;
  }

  Future<void> _clearSession() => _sessionStore.clear();

  /// 应用启动时尝试恢复上次登录的会话
  Future<void> tryRestoreSession() async {
    final session = await _sessionStore.load();
    if (session == null) return;
    if (session.token.isNotEmpty) {
      final client = getIt<DioClient>();
      client.token = session.token;
      client.updateProxy(session.proxy);
      state = AuthAuthenticated(session);
    }
  }

  /// 密码登录
  Future<void> loginWithPassword({
    required String account,
    required String password,
    String? captchaToken,
  }) async {
    state = const AuthLoading();
    try {
      final session = await _repository.loginWithPassword(
        account: account,
        password: password,
        captchaToken: captchaToken,
      );
      // 记录登录方式与密码 (供账号详情展示 / 重新登录自动填充)
      final withMethod =
          session.copyWith(loginMethod: 'password', password: password);
      state = AuthAuthenticated(await _persistSession(withMethod));
    } on PasswordChangeRequiredException catch (e) {
      // 弱密码 / 需改密：弹窗改密后重登
      state = AuthPasswordChangeRequired(
        account: e.account,
        oldPassword: e.oldPassword,
        checkToken: e.checkToken,
        message: e.message,
      );
    } on CaptchaRequiredException {
      state = AuthCaptchaRequired(
        loginMethod: 'password',
        account: account,
        credential: password,
      );
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError('登录失败: $e');
    }
  }

  /// 弱密码改密后重新登录
  ///
  /// 调用改密接口成功后，用新密码重新登录（对齐 web "密码修改成功，请重新登录"）。
  /// 若改密响应直接返回 token 则据此建会话；否则用新密码重登。
  Future<void> changePasswordAndRelogin({
    required String account,
    required String oldPassword,
    required String newPassword,
    required String checkToken,
  }) async {
    state = const AuthLoading();
    try {
      final res = await _repository.changePassword(
        oldPassword: oldPassword,
        newPassword: newPassword,
        checkToken: checkToken,
      );
      if (!res.success) {
        state = AuthError(res.msg ?? '修改密码失败');
        return;
      }
      // 用新密码重新登录（最稳妥），并更新记住的密码
      final session = await _repository.loginWithPassword(
        account: account,
        password: newPassword,
      );
      final withMethod =
          session.copyWith(loginMethod: 'password', password: newPassword);
      state = AuthAuthenticated(await _persistSession(withMethod));
    } on CaptchaRequiredException {
      // 重登触发滑块：进入滑块流程（用新密码作为 credential）
      state = AuthCaptchaRequired(
        loginMethod: 'password',
        account: account,
        credential: newPassword,
      );
    } on PasswordChangeRequiredException catch (e) {
      // 新密码仍被判定为弱密码：重新弹窗改密
      state = AuthPasswordChangeRequired(
        account: e.account,
        oldPassword: e.oldPassword,
        checkToken: e.checkToken,
        message: e.message,
      );
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError('修改密码后登录失败: $e');
    }
  }

  /// 账号中心主动改密后重新登录
  ///
  /// 调用账号中心改密接口（已登录 session 鉴权，无需 checkToken）成功后，
  /// 用新密码重新登录以刷新（旧 token 改密后通常失效）。
  /// 返回是否成功及服务端消息，供 UI（如设置页弹窗）直接判断结果。
  ///
  /// 注意：设置页无滑块/弱密码弹窗处理能力，重登若触发此类特殊流程会转为
  /// 明确错误提示，引导用户手动重新登录，避免把设置页置于未处理状态。
  Future<({bool success, String? msg})> changePasswordLoggedIn({
    required String account,
    required String oldPassword,
    required String newPassword,
  }) async {
    state = const AuthLoading();
    try {
      final res = await _repository.changePasswordLoggedIn(
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
      if (!res.success) {
        state = AuthError(res.msg ?? '修改密码失败');
        return (success: false, msg: res.msg ?? '修改密码失败');
      }
      // 用新密码重新登录，刷新会话并更新记住的密码
      try {
        final session = await _repository.loginWithPassword(
          account: account,
          password: newPassword,
        );
        final withMethod =
            session.copyWith(loginMethod: 'password', password: newPassword);
        state = AuthAuthenticated(await _persistSession(withMethod));
        return (success: true, msg: res.msg ?? '修改密码成功');
      } on AuthException catch (e) {
        state = AuthError('密码已修改，但重新登录失败：${e.message}，请手动重新登录');
        return (
          success: false,
          msg: '密码已修改，但重新登录失败：${e.message}',
        );
      } catch (e) {
        state = AuthError('密码已修改，但重新登录失败: $e，请手动重新登录');
        return (success: false, msg: '密码已修改，但重新登录失败: $e');
      }
    } on AuthException catch (e) {
      state = AuthError(e.message);
      return (success: false, msg: e.message);
    } catch (e) {
      state = AuthError('修改密码失败: $e');
      return (success: false, msg: '修改密码失败: $e');
    }
  }

  /// 取消改密（用户主动放弃），回到初始登录态
  void cancelPasswordChange() => state = const AuthInitial();

  /// 短信验证码登录
  Future<void> loginWithSms({
    required String phone,
    required String smsCode,
  }) async {
    final checkToken = _smsCheckToken;
    if (checkToken == null || checkToken.isEmpty) {
      state = const AuthError('请先获取验证码');
      return;
    }
    state = const AuthLoading();
    try {
      final session = await _repository.loginWithSms(
        phone: phone,
        smsCode: smsCode,
        checkToken: checkToken,
      );
      // 记录登录方式 (短信登录无密码可记)
      final withMethod = session.copyWith(loginMethod: 'sms');
      state = AuthAuthenticated(await _persistSession(withMethod));
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError('短信登录失败: $e');
    }
  }

  /// 发送注册短信验证码
  ///
  /// 返回 null = 成功，'CAPTCHA_REQUIRED' = 需要滑块验证，其他 = 错误信息
  Future<String?> sendRegisterSmsCode(String phone, {String? captchaToken}) async {
    try {
      await _repository.sendRegisterSmsCode(
        phone,
        captchaToken: captchaToken,
      );
      return null; // 成功
    } on CaptchaRequiredException {
      return 'CAPTCHA_REQUIRED';
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '发送失败: $e';
    }
  }

  /// 短信注册（校验验证码 + 创建账号），成功后自动以密码登录
  ///
  /// 返回 null = 成功，其他 = 错误信息
  Future<String?> registerWithSms({
    required String phone,
    required String smsCode,
    required String password,
  }) async {
    state = const AuthLoading();
    try {
      await _repository.registerWithSms(
        phone: phone,
        smsCode: smsCode,
        password: password,
      );

      // 注册成功后自动登录，直接进入已登录态 (记住注册密码)
      try {
        final session = await _repository.loginWithPassword(
          account: phone,
          password: password,
        );
        final withMethod =
            session.copyWith(loginMethod: 'password', password: password);
        state = AuthAuthenticated(await _persistSession(withMethod));
      } on AuthException catch (e) {
        // 注册已成功，但自动登录失败：仍视为成功，提示用户手动登录
        state = AuthError('注册成功，但自动登录失败：${e.message}');
      } catch (_) {
        state = const AuthError('注册成功，请使用新账号登录');
      }
      return null;
    } on CaptchaRequiredException {
      state = const AuthError('操作过于频繁，请稍后再试');
      return 'CAPTCHA_REQUIRED';
    } on AuthException catch (e) {
      state = AuthError(e.message);
      return e.message;
    } catch (e) {
      state = AuthError('注册失败: $e');
      return '注册失败: $e';
    }
  }

  /// 滑块验证通过后重试登录
  Future<void> retryWithCaptchaToken(String captchaToken) async {
    final current = state;
    if (current is! AuthCaptchaRequired) return;

    await loginWithPassword(
      account: current.account,
      password: current.credential,
      captchaToken: captchaToken,
    );
  }

  /// 发送短信验证码
  ///
  /// 返回 null = 成功，'CAPTCHA_REQUIRED' = 需要滑块验证，其他 = 错误信息
  Future<String?> sendSmsCode(String phone, {String? captchaToken}) async {
    try {
      final result = await _repository.sendSmsCode(
        phone,
        captchaToken: captchaToken,
      );
      _smsCheckToken = result.checkToken;
      if (!result.existUser) {
        return '该手机号未注册，请使用学校发放的账号登录';
      }
      return null; // 成功
    } on CaptchaRequiredException {
      return 'CAPTCHA_REQUIRED';
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return '发送失败: $e';
    }
  }

  /// Token 登录
  Future<void> loginWithToken(String token) async {
    state = const AuthLoading();
    try {
      final session = await _repository.loginWithToken(token);
      state = AuthAuthenticated(await _persistSession(session));
    } on AuthException catch (e) {
      state = AuthError(e.message);
    } catch (e) {
      state = AuthError('Token 登录失败: $e');
    }
  }

  /// 生成二维码
  Future<({String uuid, String qrcodeUrl})?> generateQRCode() async {
    try {
      return await _repository.generateQRCode();
    } catch (_) {
      return null;
    }
  }

  /// 检查二维码状态
  Future<({int status, String? token})> checkQRCodeStatus(String uuid) {
    return _repository.checkQRCodeStatus(uuid);
  }

  /// 二维码确认后完成登录
  Future<void> completeQRCodeLogin(String token) async {
    state = const AuthLoading();
    try {
      final session = await _repository.loginWithToken(token);
      // 记录登录方式 (扫码登录无密码可记)
      final withMethod = session.copyWith(loginMethod: 'qrcode');
      state = AuthAuthenticated(await _persistSession(withMethod));
    } catch (e) {
      state = AuthError('扫码登录失败: $e');
    }
  }

  /// 切换账号（仅清本地会话，不注销服务端 token）
  Future<void> switchAccount() async {
    getIt<DioClient>().token = null;
    _resetProxy();
    await _clearSession();
    state = const AuthInitial();
  }

  /// 登出
  Future<void> logout() async {
    try {
      await _repository.logout();
    } catch (_) {}
    _resetProxy();
    await _clearSession();
    state = const AuthInitial();
  }

  /// 恢复会话（手动指定）
  Future<void> restoreSession(UserSession session) async {
    getIt<DioClient>().token = session.token;
    final effective = await _persistSession(session);
    state = AuthAuthenticated(effective);
  }

  /// 更新当前登录账号的代理设置 (会话内存态 + SessionStore 持久化 + DioClient)
  ///
  /// 设置页"代理设置"写入入口; 显式设置以本次为准, 不继承已保存条目。
  /// [proxy] 为 `host:port` 格式, null/空串表示清除代理 (直连)。
  /// 未登录 (非 [AuthAuthenticated]) 或代理无变化时为 no-op。
  Future<void> updateCurrentSessionProxy(String? proxy) async {
    final current = state;
    if (current is! AuthAuthenticated) return;
    final clean = (proxy == null || proxy.trim().isEmpty) ? null : proxy.trim();
    if (current.session.proxy == clean) return;
    final updated = current.session.withProxy(clean);
    await _persistSession(updated, inheritStoredProxy: false);
    state = AuthAuthenticated(updated);
  }

  /// 登出/切换账号后恢复全局 DioClient 直连 (下个账号登录时重新应用)
  void _resetProxy() {
    if (getIt.isRegistered<DioClient>()) {
      getIt<DioClient>().updateProxy(null);
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.watch(authRepositoryProvider));
});
