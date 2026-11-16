/// 登录错误分类器（集中维护"需改密"类登录响应的判定）
///
/// 对齐 web `ewtLogin` chunk 实测逻辑（`W` 成功处理器 + `y` 失败处理器）：
///   - **改密仅在登录"成功"响应**（`success:true`）携带 `data.failCode`
///     ∈ {017179, 017180, 017442} 且带非空 `checkToken` 时触发：
///       - `017179` 需修改初始密码（web: isSetInitPassword=false）
///       - `017180` 需设置初始密码（web: isSetInitPassword=true）
///       - `017442` 强制修改密码
///   - 登录失败类响应一律不算改密：
///       - `017133` 账号或密码错误
///       - `017129` / `017130` 滑块验证（见 [CaptchaRequiredException]）
///       - `017126` / `017421` web 静默忽略（仅记录日志，不弹任何提示）
///
/// 扩展指引：若后续出现新的"需改密" `failCode`，扩充 [passwordChangeFailCodes]
/// 即可，调用方无需逐处修改。
abstract final class LoginErrorClassifier {
  /// 登录成功响应 `data.failCode` 命中集合 → 需改密
  static const Set<String> passwordChangeFailCodes = {
    '017179', // 需修改初始密码
    '017180', // 需设置初始密码
    '017442', // 强制修改密码
  };

  /// 判断登录响应是否属于"需改密"类。
  ///
  /// 仅当响应业务成功（[isSuccess]）且 `data.failCode` 命中
  /// [passwordChangeFailCodes]、并携带非空 `checkToken` 时返回 true；
  /// 其余（密码错误、滑块、017126/017421、普通成功登录等）一律返回 false。
  static bool isPasswordChangeRequired({
    required String code,
    String? failCode,
    required String msg,
    required bool isSuccess,
    Map<String, dynamic>? data,
  }) {
    // 对齐 web：改密只在 success=true 且 promise resolve 的响应上判断
    if (!isSuccess || data == null) return false;
    final fail = (data['failCode'] ?? failCode)?.toString();
    if (fail == null || !passwordChangeFailCodes.contains(fail)) return false;
    // 改密接口需要 checkToken（web: checkToken 传给改密弹窗/接口）
    final checkToken = data['checkToken']?.toString();
    return checkToken != null && checkToken.isNotEmpty;
  }

  /// 从响应 `data` 中提取改密接口所需的 `checkToken`（兼容 `token` 兜底）
  static String? extractCheckToken(Map<String, dynamic>? data) {
    if (data == null) return null;
    final v = data['checkToken'] ?? data['token'];
    return v?.toString();
  }
}

/// 需修改密码异常（弱密码等）
///
/// 由 [AuthRemoteDataSource.loginWithPassword] 在识别到"需改密"响应时抛出，
/// 携带用于改密接口的 [checkToken] 与原始账号 / 旧密码，供 UI 弹窗改密后重登。
class PasswordChangeRequiredException implements Exception {
  final String account;
  final String oldPassword;
  final String? checkToken;
  final String message;
  final String? failCode;

  const PasswordChangeRequiredException({
    required this.account,
    required this.oldPassword,
    this.checkToken,
    required this.message,
    this.failCode,
  });

  @override
  String toString() => message;
}
