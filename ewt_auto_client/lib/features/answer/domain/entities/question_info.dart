/// 题目信息实体
///
/// 对应 Python: tasks/utils.py _extract_question_info
class QuestionInfo {
  final String number;
  final String group;
  final String answer;
  final String analysis;
  final String knowledge;
  final String questionType;
  final String questionContent;
  final List<String> options;
  final List<QuestionInfo> childQuestions;
  final String difficulty;

  // ─── 提交相关原始字段 (对齐 Web answerSheetInfo / answer/paper 响应) ───
  /// 题目 ID (对应 API 的 id / questionId)
  final String id;
  /// 题型代码 (对应 API 的 cate, 如 5=解答, 21=阅读理解)
  final int cate;
  /// 是否主观题 (对应 API 的 subjective)
  final bool subjective;
  /// 显示题号 (对应 API 的 questionNoShow, 如 "1"/"1-2")
  final String questionNoShow;
  /// 题目排序 (对应 API 的 questionSort)
  final int questionSort;
  /// 父题 ID (子题才有, 对应 API 的 parentQuestionId)
  final String parentId;
  /// 原始正确答案数组 (对应 API 的 rightAnswer, 未格式化, 用于提交时参考)
  final List<String> rightAnswerRaw;

  const QuestionInfo({
    this.number = '',
    this.group = '',
    this.answer = '',
    this.analysis = '',
    this.knowledge = '',
    this.questionType = '',
    this.questionContent = '',
    this.options = const [],
    this.childQuestions = const [],
    this.difficulty = '',
    this.id = '',
    this.cate = 0,
    this.subjective = false,
    this.questionNoShow = '',
    this.questionSort = 0,
    this.parentId = '',
    this.rightAnswerRaw = const [],
  });

  /// 从 API 返回的题目 data 中提取完整信息 (含子题递归)
  ///
  /// 对应 Python: tasks/utils.py _extract_question_info
  factory QuestionInfo.fromJson(Map<String, dynamic> data, {String number = '', String group = ''}) {
    final answer = _formatAnswer(data);
    final analysis = _normalizeImgUrls(
      (data['analyse'] ?? data['method'] ?? '').toString(),
    );
    final knowledges = ((data['knowledges'] as List<dynamic>?) ?? [])
        .map((k) => (k is Map ? k['title']?.toString() ?? '' : ''))
        .where((s) => s.isNotEmpty)
        .join('、');
    final questionType = (data['subjectQuestionTypeName'] ??
            data['questionTypeName'] ??
            data['cateName'] ??
            '')
        .toString();
    final questionContent =
        _normalizeImgUrls((data['questionContent'] ?? '').toString());

    final options = <String>[];
    final optList = (data['options'] as List<dynamic>?) ?? [];
    for (int i = 0; i < optList.length; i++) {
      final opt = optList[i];
      if (opt is String) {
        // 字符串型选项 (如 "A. 选项内容"), 直接使用
        if (opt.trim().isNotEmpty) {
          options.add(opt);
        }
      } else if (opt is Map<String, dynamic>) {
        final choice = opt['choice']?.toString() ?? '';
        // 兼容多种字段名: option / content / text / value
        final optionText = _normalizeImgUrls(
          (opt['option'] ?? opt['content'] ?? opt['text'] ?? opt['value'] ?? '')
              .toString(),
        );
        // choice 缺失时用 A/B/C/D 序号兜底, 确保选项不丢失
        final effectiveChoice = choice.isNotEmpty
            ? choice
            : String.fromCharCode(65 + i); // A, B, C, D...
        if (optionText.isNotEmpty) {
          options.add('$effectiveChoice. $optionText');
        }
      }
    }

    final childQuestions = <QuestionInfo>[];
    final children = (data['childQuestions'] as List<dynamic>?) ?? [];
    for (int i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is Map<String, dynamic>) {
        childQuestions.add(QuestionInfo.fromJson(
          child,
          number: '${i + 1}',
        ));
      }
    }

    // ─── 提交相关原始字段提取 ───
    final rawId = (data['id'] ?? data['questionId'] ?? '').toString();
    final rawCate = data['cate'] ?? data['cateId'] ?? 0;
    final rawSubjective = data['subjective'] ?? false;
    final rawQuestionNoShow =
        (data['questionNoShow'] ?? data['questionNumber'] ?? '').toString();
    final rawQuestionSort = data['questionSort'] ?? 0;
    final rawParentId = (data['parentQuestionId'] ?? '').toString();
    // rightAnswer 原始数组 (未格式化)
    final rawRightAnswer = data['rightAnswer'];
    final rightAnswerList = <String>[];
    if (rawRightAnswer is List) {
      rightAnswerList.addAll(
        rawRightAnswer.map((e) => e.toString()).where((s) => s.isNotEmpty),
      );
    }

    return QuestionInfo(
      number: number,
      group: group,
      answer: answer,
      analysis: analysis,
      knowledge: knowledges,
      questionType: questionType,
      questionContent: questionContent,
      options: options,
      childQuestions: childQuestions,
      difficulty: (data['degreeRangeDesc'] ?? '').toString(),
      id: rawId,
      cate: rawCate is int ? rawCate : int.tryParse(rawCate.toString()) ?? 0,
      subjective: rawSubjective is bool
          ? rawSubjective
          : rawSubjective.toString() == 'true',
      questionNoShow: rawQuestionNoShow,
      questionSort: rawQuestionSort is int
          ? rawQuestionSort
          : int.tryParse(rawQuestionSort.toString()) ?? 0,
      parentId: rawParentId,
      rightAnswerRaw: rightAnswerList,
    );
  }

  /// 从 rightAnswer 提取答案文本
  ///
  /// 对齐 Web answer-pc 渲染逻辑 (shared-hZ0qNeAu.js):
  /// - rightAnswer 为数组时, Web 端按 `pm-label-value-item` 逐个渲染:
  ///   · answers.length > 3: 渲染为 "序号、答案" 格式 (每项前加序号)
  ///   · answers.length <= 3: 直接渲染每项 (不加序号)
  /// - 选择题 (全为 A-Z): 合并为 "A, B, C" 文本
  /// - 主观题/填空题 (含 HTML): 逐项保留 HTML, 用 <br> 分隔,
  ///   多答案时每项前加 "序号、" 前缀 (对齐 Web 的 pm-label-value-item)
  ///
  /// 修复: 原实现仅取 rightAnswer.first, 导致多答案主观题 (如名句默写 50 空)
  /// 只展示第一个答案, 其余丢失。现对齐 Web 完整渲染所有答案。
  static String _formatAnswer(Map<String, dynamic> data) {
    final rightAnswer = data['rightAnswer'];
    // 列表型 rightAnswer: 服务端答案未解锁时返回空数组 []
    // 必须显式处理, 否则空数组会落到下方 rightAnswer?.toString() 返回字面字符串 "[]",
    // 导致 hasAnswer 误判为 true, 题目被直接收集而跳过 getQuestionAnalysis 逐题补全,
    // 答案栏显示为 "[]" (paperId 越权方案的典型症状)。
    if (rightAnswer is List) {
      if (rightAnswer.isEmpty) return '';
      final list = rightAnswer
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (list.isEmpty) return '(主观题)';

      // 选择题: 全部为 A-Z 选项时, 合并为 "A, B, C"
      final opts = list.where((s) => RegExp(r'^[A-Z]+$').hasMatch(s)).toList();
      if (opts.length == list.length) {
        return opts.join(', ');
      }

      // 主观题/填空题: 逐项保留 HTML, 对齐 Web 渲染
      // 多答案 (>3) 时每项前加 "序号、" 前缀, 用 <br> 分隔
      // 单答案或 <=3 项时直接拼接 (对齐 Web answers.length<=3 分支)
      if (list.length == 1) {
        return _normalizeImgUrls(list.first);
      }
      // 多答案: 每项加序号前缀, <br> 分隔
      // (对齐 Web: pm-label-value-item 内 "序号、答案HTML")
      final parts = <String>[];
      for (int i = 0; i < list.length; i++) {
        parts.add('${i + 1}、${_normalizeImgUrls(list[i])}');
      }
      return parts.join('<br>');
    }
    // 字符串型 rightAnswer
    // 防御: 字符串 "[]" 视为空数组 (服务端序列化异常时可能出现)
    final ans = rightAnswer?.toString() ?? '';
    if (ans.isEmpty || ans == '[]') return '';
    return _normalizeImgUrls(ans);
  }

  /// 补全 HTML 中 img src 为绝对 HTTPS URL
  ///
  /// EWT 平台数学公式 (Wirisformula) 使用 file.ewt360.com 图片,
  /// 但 API 返回的 src 可能是:
  /// - http://file.ewt360.com/... (HTTP 明文, Flutter 默认阻止, 必须转 HTTPS)
  /// - //file.ewt360.com/... (协议相对)
  /// - /path (站内相对, 补全为 web.ewt360.com)
  /// - https://file.ewt360.com/... (已正确, 不处理)
  static String _normalizeImgUrls(String text) {
    if (text.isEmpty) return '';
    // http://host/path → https://host/path (HTTP 转 HTTPS, 解决明文阻止)
    // 注意: group(1) 包含 "http://" 前缀, 必须去掉后再拼 "https://"
    var result = text.replaceAllMapped(
      RegExp(r'''src=["']?http://([^"\s>]+)["']?'''),
      (m) => 'src="https://${m.group(1)}"',
    );
    // //host/path → https://host/path
    result = result.replaceAllMapped(
      RegExp(r'''src=["']?//([^"\s>]+)["']?'''),
      (m) => 'src="https://${m.group(1)}"',
    );
    // /path → https://web.ewt360.com/path (仅非 http 开头)
    result = result.replaceAllMapped(
      RegExp(r'''src=["']?/([^"\s>]+)["']?'''),
      (m) {
        final path = m.group(1) ?? '';
        if (path.startsWith('http')) return m.group(0)!;
        return 'src="https://web.ewt360.com/$path"';
      },
    );
    return result;
  }
}

/// 单个课程的答案结果
///
/// 对应 Python: tasks/course_batch.py 中的 answer_data
class CourseAnswerResult {
  final String courseTitle;
  final String method;
  final String paperId;
  final List<QuestionInfo> questions;
  final int successCount;
  final int totalCount;

  /// 日期 ID (YYYY-MM-DD 格式, 来自 course.day_id)
  ///
  /// 对应 Python: answer_data.day_id
  final String dayId;

  /// 日期标签 (复用 dayId, 用于导出文件名/标题)
  ///
  /// 对应 Python: answer_data.date_label
  final String dateLabel;

  /// 学科名称 (如 "语文"/"数学", 来自 course.subjectName)
  ///
  /// 用于导出文件名规则 {课程学科}
  final String subjectName;

  // ─── 提交相关字段 (对齐 Web answer-pc 页面 state) ───
  /// 答题报告 ID (对应 Web state.reportId, 提交时必传)
  final String reportId;
  /// 业务码 (对应 Web state.bizCode, 如 "204"/"205")
  final String bizCode;
  /// 作业 ID (对应 Web state.homeworkId, bizCode=205 时必传)
  final String homeworkId;
  /// 平台 (对应 Web state.platform, 固定 "1")
  final String platform;
  /// 是否赋分模式 (对应 Web state.assignPoints, 影响提交载荷)
  final bool assignPoints;
  /// 试卷包 ID (对应 Web state.paperPackageId, 最终交卷时传)
  final String paperPackageId;
  /// 用户 ID (对应 Web state.userId)
  final String userId;

  const CourseAnswerResult({
    required this.courseTitle,
    required this.method,
    required this.paperId,
    required this.questions,
    required this.successCount,
    required this.totalCount,
    this.dayId = '',
    this.dateLabel = '',
    this.subjectName = '',
    this.reportId = '',
    this.bizCode = '204',
    this.homeworkId = '',
    this.platform = '1',
    this.assignPoints = false,
    this.paperPackageId = '',
    this.userId = '',
  });

  /// 创建副本, 仅覆盖指定字段 (用于在不修改原对象的情况下补充提交字段)
  CourseAnswerResult copyWith({
    String? reportId,
    String? bizCode,
    String? homeworkId,
    String? platform,
    bool? assignPoints,
    String? paperPackageId,
    String? userId,
  }) {
    return CourseAnswerResult(
      courseTitle: courseTitle,
      method: method,
      paperId: paperId,
      questions: questions,
      successCount: successCount,
      totalCount: totalCount,
      dayId: dayId,
      dateLabel: dateLabel,
      subjectName: subjectName,
      reportId: reportId ?? this.reportId,
      bizCode: bizCode ?? this.bizCode,
      homeworkId: homeworkId ?? this.homeworkId,
      platform: platform ?? this.platform,
      assignPoints: assignPoints ?? this.assignPoints,
      paperPackageId: paperPackageId ?? this.paperPackageId,
      userId: userId ?? this.userId,
    );
  }
}
