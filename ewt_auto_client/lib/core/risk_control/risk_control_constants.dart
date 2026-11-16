/// 风控配置常量
///
/// 与 Python 端 `RiskControl/generate_encrypted_config.py` 保持一致。
class RiskControlConstants {
  RiskControlConstants._();

  /// 远程配置页面 (腾讯分享链)
  static const String sharechainUrl =
      'https://sharechain.qq.com/9c1f20bdc8df0fe241dfdf9eda2131b3?qq_aio_chat_type=2';

  /// 配置密文首尾标记
  static const String configMarker = '@############################@';

  /// 配置密钥派生种子 (master=sha256(seed), 再派生 ChaChaKey/Nonce/FeistelKey)
  static const String aesSeed = 'xxhy123';

  /// 加载失败提示
  static const String loadFailMessage = '连接服务器失败，请稍后重试';

  /// 风控总开关 (硬编码)
  ///
  /// 设为 `false` 时:
  ///   1) [RiskControlGate.isFeatureEnabled] 对任意 key 返回 `true` -> 全部放行 (不限制);
  ///   2) `main.dart` 跳过整个风控启动流程 -> 不会因配置获取失败而弹窗退出。
  ///
  /// 仅用于内部调试 / 授权分发; 正式构建务必保持 `true`。
  static const bool kRiskControlEnabled = false;

  /// 标准 Base64 字母表
  static const String stdAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  /// 变种 Base64 字母表 (STD 反转后将 + -> _ , / -> -)
  static const String customAlphabet =
      '-_9876543210zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA';
}
