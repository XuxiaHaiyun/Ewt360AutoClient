/// 应用级常量
abstract final class AppConstants {
  static const String appName = 'EWT Auto Client';
  // 版本号不再写死, 由设置页从 assets/changelog.json 首条记录动态读取

  // ─── 视频配置 ───
  static const String defaultVideoBizCode = '1013';
  static const int defaultPlayerType = 1;

  /// 心跳间隔（秒）
  static const int reportInterval = 60;

  /// 视频完成阈值 (80%)
  static const double completionThreshold = 0.8;

  /// 专注检查最小视频时长（秒）
  static const int checkPointMinDuration = 180;

  /// 进度持久化间隔（秒）
  static const int progressPersistInterval = 300;

  // ─── BFE 播放器标识 (WEB 端 sn) ───
  static const String playerSn = 'ewt_web_video_detail';

  // ─── 网络默认值 ───
  static const int defaultTimeout = 10;
  static const int downloadTimeout = 30;
  static const int uploadTimeout = 60;
  static const int maxRetries = 3;
  static const double retryDelay = 1.0;
  static const int requestInterval = 100; // ms

  // ─── 二维码轮询 ───
  static const int qrcodePollInterval = 3; // 秒
  static const int qrcodeExpireSeconds = 300;
}
