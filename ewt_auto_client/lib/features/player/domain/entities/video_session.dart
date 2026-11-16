/// 视频播放会话实体
///
/// 对应 Python: tasks/player_behavior.py 中一次完整播放模拟的上下文
class VideoSession {
  final String homeworkId;
  final String lessonId;
  final String videoId;

  /// 任务 ID (refreshTaskProgress / taskProgressV1 必传)
  ///
  /// 对应 Python: course.task_id
  final String taskId;

  /// contentType (1=视频 / 2=试卷 / 3=FM / 4=资讯 / 5=板报)
  final int contentType;

  /// 课程包 ID (getLessonDetailV2.data.courseId) - 可由服务初始化时更新
  String? courseId;

  /// 学校 ID (getPlayerToken 必传)
  final String schoolId;

  /// BFE 会话标识
  final String sessionId;
  final String secret;

  /// 视频时长（秒）- 可由引擎初始化时更新
  int duration;

  /// 播放 token - 可由引擎初始化时更新
  String? playerToken;

  /// 腾讯 VOD appId (用于 getplayinfo)
  final int? appId;

  /// 互动视频配置 (getExternalVideoInfo.interactiveInfo.interactiveConfigList)
  List<InteractiveConfig> interactiveConfigs;

  /// 当前已播放时间（秒）
  int playedTime;

  /// 是否已完成
  bool isCompleted;

  // ─── BFE CommonPackage 所需用户/环境上下文 ───

  /// 用户 ID (CommonPackage.userid)
  final String userId;

  /// 用户 token (CommonPackage.mstid)
  final String token;

  /// 客户端 IP (CommonPackage.ip, 来自 getPlayerGlobalConf.globalInfo.clientIp)
  final String clientIp;

  /// 用户省份码 (CommonPackage.memberProvinceCode)
  final String memberProvinceCode;

  /// 学校省份码 (CommonPackage.schoolProvinceCode)
  final String schoolProvinceCode;

  VideoSession({
    required this.homeworkId,
    required this.lessonId,
    required this.videoId,
    this.taskId = '',
    this.contentType = 1,
    this.courseId,
    this.schoolId = '',
    required this.sessionId,
    required this.secret,
    required this.duration,
    this.playerToken,
    this.appId,
    this.interactiveConfigs = const [],
    this.playedTime = 0,
    this.isCompleted = false,
    this.userId = '',
    this.token = '',
    this.clientIp = '',
    this.memberProvinceCode = '',
    this.schoolProvinceCode = '',
  });

  /// 是否需要专注检查（视频 > 180s）
  bool get needsFocusCheck => duration > 180;

  /// 完成进度百分比
  double get progress =>
      duration > 0 ? (playedTime / duration).clamp(0.0, 1.0) : 0.0;
}

/// 互动视频配置点 (对应 Python `_extract_interactive_configs` 中的项)
///
/// 来自 getExternalVideoInfo.interactiveInfo.interactiveConfigList
class InteractiveConfig {
  /// 互动点 ID (提交答案 / addVideoss 使用)
  final String id;

  /// 触发时间点 (毫秒)
  final int timePoint;

  const InteractiveConfig({
    required this.id,
    this.timePoint = 0,
  });
}

/// 播放模拟状态
enum PlaybackState {
  /// 初始化中（获取 session/token/videoInfo）
  initializing,

  /// 起始 burst（record/submit + 初始遥测）
  starting,

  /// 正常播放（心跳循环中）
  playing,

  /// 专注检查暂停
  focusChecking,

  /// 互动答题
  interactive,

  /// 结束 burst（最终遥测 + 进度持久化）
  finishing,

  /// 完成
  completed,

  /// 失败
  failed,

  /// 已取消
  cancelled,
}

/// 播放进度事件（通过 Stream 暴露给 UI）
class PlaybackProgress {
  final PlaybackState state;
  final int playedSeconds;
  final int totalSeconds;
  final String? message;
  final String? error;

  const PlaybackProgress({
    required this.state,
    required this.playedSeconds,
    required this.totalSeconds,
    this.message,
    this.error,
  });

  double get fraction =>
      totalSeconds > 0 ? (playedSeconds / totalSeconds).clamp(0.0, 1.0) : 0.0;
}
