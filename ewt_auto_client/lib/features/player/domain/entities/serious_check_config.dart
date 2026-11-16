/// 认真度检测降级配置
///
/// 对应浏览器播放页 getSeriousCheckDownGradeConfig 接口返回的 data 字段:
///   {key, level, tips, needLog, description}
///
/// 对齐文档 mstplayer_seriousness_check_doc.md §2.0.5 / §6 / §7.1:
/// - [level]==0: 正常检测, 所有认真度机制生效 (执行完整流程)
/// - [level]>0:  降级模式, 关闭认真度检测 (高峰期兜底, 仅记录日志不执行打断/滑块)
///
/// [needLog] 为是否记录检测日志的开关 (1=记录, 0=不记录), 与降级判断无关。
class SeriousCheckConfig {
  /// 降级等级 (0=正常, >0=降级)
  ///
  /// 接口失败时的默认值为 1 (降级), 作为安全 fallback 避免在未知环境下
  /// 触发滑块验证导致自动化流程卡死。
  final int level;

  /// 提示文案 (降级时显示给用户)
  final String tips;

  /// 是否记录检测日志 (1=记录, 0=不记录)
  final int needLog;

  /// 描述
  final String description;

  const SeriousCheckConfig({
    this.level = 1,
    this.tips = '',
    this.needLog = 0,
    this.description = '',
  });

  /// 是否为降级模式 (仅记录日志, 不执行打断/滑块)
  ///
  /// 对齐文档: level>0 时为降级模式, 播放器不弹出认真度检测弹窗,
  /// 仅在后端记录日志。此时进度上报照常进行, 但不执行 act=3 暂停和滑块验证。
  bool get isDowngrade => level > 0;

  /// 认真度检测功能是否可用 (执行完整流程)
  bool get isEnabled => !isDowngrade;

  factory SeriousCheckConfig.fromJson(Map<String, dynamic> json) {
    return SeriousCheckConfig(
      level: json['level'] is int
          ? json['level'] as int
          : int.tryParse(json['level']?.toString() ?? '') ?? 1,
      tips: json['tips']?.toString() ?? '',
      needLog: json['needLog'] is int
          ? json['needLog'] as int
          : int.tryParse(json['needLog']?.toString() ?? '') ?? 0,
      description: json['description']?.toString() ?? '',
    );
  }

  @override
  String toString() =>
      'SeriousCheckConfig(level=$level, needLog=$needLog, tips=$tips)';
}
