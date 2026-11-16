/// 作业级筛选配置
///
/// 用于批量任务执行前, 按 状态/学科/类型 筛选作业列表 (getHomeworkList)。
/// 对应 Python: gui/dialogs 中作业筛选条件 (status / subject / type)。
///
/// 与 [AnswerFilterConfig] / [ReportConfig] 的区别:
/// - 本配置作用于 **作业列表** (homework 级), 决定拉取哪些作业
/// - AnswerFilterConfig / ReportConfig 中的 selectedTypes/selectedSubjects
///   作用于 **课程列表** (course 级), 决定处理作业内的哪些课程
class TaskFilterConfig {
  /// 作业状态筛选 (null=全部, 1=未开始, 2=进行中, 3=已截止)
  ///
  /// 对应 getHomeworkList 的 status 参数
  final int? status;

  /// 学科筛选 (null=全部, 1-12 对应 12 个学科)
  ///
  /// 对应 getHomeworkList 的 subject 参数
  final int? subject;

  /// 作业类型筛选 (null=全部试卷测评, 2=选科视频, 3=学科专项专题)
  ///
  /// 对应 getHomeworkList 的 type 参数
  final int? type;

  const TaskFilterConfig({
    this.status,
    this.subject,
    this.type,
  });

  /// 默认配置: 进行中 + 全部学科 + 全部类型
  const TaskFilterConfig.defaults()
      : status = 2,
        subject = null,
        type = null;

  TaskFilterConfig copyWith({
    int? Function()? status,
    int? Function()? subject,
    int? Function()? type,
  }) {
    return TaskFilterConfig(
      status: status != null ? status() : this.status,
      subject: subject != null ? subject() : this.subject,
      type: type != null ? type() : this.type,
    );
  }
}
