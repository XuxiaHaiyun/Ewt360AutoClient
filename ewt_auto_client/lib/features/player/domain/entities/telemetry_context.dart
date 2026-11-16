/// BFE/CLOG/DLOG 遥测上下文 (CommonPackage 级别常量)
///
/// 对应 Python: core/player.py `_build_collect_common` (WEB 端)。
/// 这些字段在一次播放会话内保持不变，用于构建上报请求体的 `CommonPackage`。
///
/// 服务端通过 `log.CommonPackage.userid` 解构用户身份，缺少该对象会返回
/// code=699999 "Cannot destructure property 'userid' of 'log.CommonPackage'"。
class TelemetryContext {
  /// 用户 ID (`CommonPackage.userid`，WEB 端为整型)
  final String userId;

  /// 用户 token (`CommonPackage.mstid`，同请求头 Token)
  final String token;

  /// 客户端 IP (`CommonPackage.ip`，来自 getPlayerGlobalConf.globalInfo.clientIp)
  final String clientIp;

  /// 学校 ID (`CommonPackage.schoolId`)
  final String schoolId;

  /// 用户省份码 (`CommonPackage.memberProvinceCode`)
  final String memberProvinceCode;

  /// 学校省份码 (`CommonPackage.schoolProvinceCode`)
  final String schoolProvinceCode;

  /// SDK 版本 (`CommonPackage.sdkVersion`，WEB=3.0.37)
  final String sdkVersion;

  /// 浏览器完整 UA (`CommonPackage.browser_ver`)
  final String userAgent;

  /// 视频业务码 (`CommonPackage.videoBizCode`，WEB=1013)
  final String videoBizCode;

  /// 场景标识 (顶层 `sn`，WEB=ewt_web_video_detail)
  final String playerSn;

  const TelemetryContext({
    required this.userId,
    required this.token,
    required this.clientIp,
    required this.schoolId,
    required this.memberProvinceCode,
    required this.schoolProvinceCode,
    required this.sdkVersion,
    required this.userAgent,
    required this.videoBizCode,
    required this.playerSn,
  });
}
