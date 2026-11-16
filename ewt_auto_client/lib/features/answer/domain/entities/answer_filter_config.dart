/// 试题答案过滤配置
///
/// 对应 Python: gui/dialogs/answer_filter.py AnswerFilterDialog 配置项
///
/// 在点击"试题答案"且选完方案后弹出配置弹窗, 让用户配置:
/// - 是否过滤无作业课程 (taskId 为空)
/// - 是否过滤已完成作业课程 (homeworkFinishStatus == 1)
/// - 获取答案的课程类型 (多选: 全部/视频/试卷/FM/资讯/板报/测评/课后习题/校本视频/校本试卷/...)
/// - 获取答案的课程学科 (多选: 15 个学科)
///
/// 过滤逻辑由 [AnswerService.applyFilter] 在任务启动前预先应用, 避免获取无用数据。
class AnswerFilterConfig {
  /// 是否过滤无作业课程 (无题目且无导学案: itemCount/questionCount 无题
  /// 且 studyGuideId 为空, 如 FM/资讯/板报, 默认 true)
  final bool filterNoHomework;

  /// 是否过滤已完成课程 (homeworkFinishStatus / finished / allFinished /
  /// taskStatus==30 任一命中即视为已完成, 默认 false)
  final bool filterCompleted;

  /// 选中的 contentType 列表
  ///
  /// null=全部, 1=视频, 2=试卷, 3=FM, 4=资讯, 5=板报, 6=测评, 7=课后习题,
  /// 11=校本视频, 12=校本试卷, 13=模拟选科, 14=B端测评, 15=专题, 16=课程包,
  /// 17=直播, 18=选科测评, 19=专题, 20=学科专项, 21=模拟选科决策分析
  /// 列表内含 null 时表示"全部", 不过滤类型
  final List<int?> selectedTypes;

  /// 选中的课程学科名称列表 (如 ['语文', '数学'])
  ///
  /// 空列表表示不按学科过滤 (行为等同全选)
  final List<String> selectedSubjects;

  const AnswerFilterConfig({
    this.filterNoHomework = true,
    this.filterCompleted = false,
    this.selectedTypes = const [null],
    this.selectedSubjects = const [],
  });

  /// 是否包含全部类型（不过滤）
  bool get isAllTypes => selectedTypes.contains(null);

  /// 检查某个 contentType 是否应被保留
  bool shouldKeepType(int? contentType) {
    if (isAllTypes) return true;
    if (contentType == null) return false;
    return selectedTypes.contains(contentType);
  }

  /// 检查某个学科是否应被保留
  ///
  /// 主判断: subjectName 精确匹配
  /// 备用判断: subjectId 反查 [kSubjectIdToName] 后匹配
  bool shouldKeepSubject(String? subject) {
    if (selectedSubjects.isEmpty) return true;
    if (subject == null || subject.isEmpty) return false;
    return selectedSubjects.contains(subject);
  }
}

/// 课程类型选项 (对应 Python COURSE_TYPES, 对齐 EWT Web 1225.80da63bc56.js)
///
/// (显示名, contentType 值), null 表示"全部"
const List<({String label, int? value})> kCourseTypeOptions = [
  (label: '全部', value: null),
  (label: '视频', value: 1),
  (label: '试卷', value: 2),
  (label: 'FM', value: 3),
  (label: '资讯', value: 4),
  (label: '板报', value: 5),
  (label: '测评', value: 6),
  (label: '课后习题', value: 7),
  (label: '校本视频', value: 11),
  (label: '校本试卷', value: 12),
  (label: '模拟选科', value: 13),
  (label: 'B端测评', value: 14),
  (label: '专题', value: 15),
  (label: '课程包', value: 16),
  (label: '直播', value: 17),
  (label: '选科测评', value: 18),
  (label: '专题', value: 19),
  (label: '学科专项', value: 20),
  (label: '模拟选科决策分析', value: 21),
];

/// 课程学科本地列表 (备用, 对齐 getStudentHomeworkDaySubjectStat 接口实际返回)
///
/// subjectId 10/11/12 的实际名称为 "心灵成长"/"生涯规划"/"综合素养",
/// 而非早期 Web JS 中的简称 "心理"/"生涯"/"素养"。
const List<String> kCourseSubjects = [
  '语文',
  '数学',
  '英语',
  '物理',
  '化学',
  '生物',
  '政治',
  '历史',
  '地理',
  '心灵成长',
  '生涯规划',
  '综合素养',
  '信息',
  '通用',
  '科学',
];

/// 学科 ID → 名称映射 (对齐 getStudentHomeworkDaySubjectStat 接口实际返回)
///
/// 用于 [AnswerService.applyFilter] 的备用判断: 当 subjectName 不在选中列表时,
/// 通过 subjectId 反查名称后再匹配。
const Map<int, String> kSubjectIdToName = {
  1: '语文',
  2: '数学',
  3: '英语',
  4: '物理',
  5: '化学',
  6: '生物',
  7: '政治',
  8: '历史',
  9: '地理',
  10: '心灵成长',
  11: '生涯规划',
  12: '综合素养',
  13: '综合素养',
  14: '信息',
  15: '通用',
  16: '科学',
};
