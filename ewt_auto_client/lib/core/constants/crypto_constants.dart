/// 安全相关常量（密钥、签名密钥等）
abstract final class CryptoConstants {
  // ─── AES 密码加密 ───
  static const String aesKey = '20171109124536982017110912453698';
  static const String aesIv = '2017110912453698';

  // ─── WEB 请求签名 ───
  static const String webSignSecretKey = 'bdc739ff2dcf';
  static const String webSecretId = '2';
  static const String webPlatform = '1';

  // ─── DLOG / Safecenter 签名 ───
  /// 同时用于 DLOG 签名和 safecenter checkSign 生成
  static const String dlogSignKey = 'eo^nye1j#!wt2%v)';

  // ─── 滑块验证 bizCode ───
  static const String passwordCaptchaBizCode = 'mst1784513466143';
  static const String smsCaptchaBizCode = 'mst1634782715743';
  /// 短信注册滑块验证 bizCode（来自 web 注册页实时捕获）
  static const String registerSmsCaptchaBizCode = 'mst1634784055587';
}
