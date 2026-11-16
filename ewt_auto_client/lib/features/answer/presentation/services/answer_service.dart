/// 试题答案获取服务，按方案（direct/escalation/favorites）批量抓取课程答案，并发上限 5，userId 带会话缓存。
/// 提交试卷场景用 neutralLog 隐藏"获取答案/方案"字样，日志经 logStream 供进度弹窗订阅。
library;

import 'dart:async';

import '../../../../core/network/dio_client.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../../player/domain/entities/video_session.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../data/datasources/answer_remote_datasource.dart';
import '../../domain/entities/answer_filter_config.dart';
import '../../domain/entities/question_info.dart';
import '../../../homework/data/datasources/homework_remote_datasource.dart';

/// 收藏夹并发上限 (对齐 Python MAX_FAV_WORKERS=5)
const int _kMaxFavWorkers = 5;

/// 答案解析并发上限 (逐题查询 getQuestionAnalysis 的并发工作线程数)
///
/// 用于 _fetchDirect / _fetchViaEscalation 中"答案为空题"的批量补全,
/// 替代原先串行+300ms 延迟的实现, 显著缩短大批量试卷的答案获取时间。
const int _kMaxAnalysisWorkers = 5;

/// 试题答案获取服务
///
/// 对应 Python: tasks/course_batch.py CourseBatchTask._fetch_answers*
/// 支持三种方案: direct (bizCode=204) / reportId (bizCode=201) / favorites (收藏夹机制)
class AnswerService {
  final AnswerRemoteDataSource _answerRemote;
  final HomeworkRemoteDataSource _homeworkRemote;

  final _logController = StreamController<ProgressLogEvent>.broadcast();
  bool _cancelled = false;
  bool _disposed = false;

  /// userId 缓存 (避免每次 _fetchViaEscalation 回退 answerSheetInfo 时都调用 baseinfo)
  ///
  /// 一次会话内 userId 不会变化, 缓存后多次课程复用, 减少 API 调用。
  String? _userIdCache;

  AnswerService({required DioClient client})
    : _answerRemote = AnswerRemoteDataSource(client),
      _homeworkRemote = HomeworkRemoteDataSource(client);

  Stream<ProgressLogEvent> get logStream => _logController.stream;

  void _log(String msg, {LogLevel level = LogLevel.info}) {
    if (_disposed || _logController.isClosed) return;
    _logController.add(ProgressLogEvent(msg, level: level));
  }

  /// 当前日期字符串 (YYYY-MM-DD), 用于 dateLabel 回退
  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  void cancel() {
    _cancelled = true;
    _log('用户停止获取答案', level: LogLevel.warning);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _logController.close();
  }

  /// 获取 userId (带缓存, 避免每课程都调用 baseinfo 接口)
  ///
  /// 一次会话内 userId 不会变化, 首次调用后缓存, 后续直接复用。
  Future<String> _getUserIdCached() async {
    if (_userIdCache != null && _userIdCache!.isNotEmpty) {
      return _userIdCache!;
    }
    final id = await _answerRemote.getUserId();
    if (id.isNotEmpty) _userIdCache = id;
    return id;
  }

  /// 批量获取答案
  ///
  /// [courses] 课程列表
  /// [homeworkId] 作业 ID
  /// [schoolId] 学校 ID
  /// [method] "direct" | "escalation" | "favorites" | "questions"(提交试卷独立取题)
  /// [filterConfig] 可选的过滤配置 (对应 Python AnswerFilterDialog)
  /// [onItemUpdate] 进度回调
  /// [courseInterval] 课程之间的固定请求间隔 (提交试卷场景固定 1s)
  /// [analysisWorkers] 逐题查询答案为空的并发上限; 为 1 时即串行 (不并发)
  /// [neutralLog] 提交试卷场景: 日志不出现"获取答案"/"方案"字样
  Future<List<CourseAnswerResult>> executeBatch(
    List<Map<String, dynamic>> courses, {
    required String homeworkId,
    required String schoolId,
    String method = 'auto',
    AnswerFilterConfig? filterConfig,
    void Function(int index, TaskProgressItem item)? onItemUpdate,
    Duration courseInterval = const Duration(milliseconds: 500),
    int analysisWorkers = _kMaxAnalysisWorkers,
    bool neutralLog = false,
  }) async {
    _cancelled = false;

    // 应用过滤配置 (对应 Python _apply_answer_filter)
    final filtered = filterConfig != null
        ? applyFilter(courses, filterConfig)
        : courses;

    final results = <CourseAnswerResult>[];
    final total = filtered.length;

    if (neutralLog) {
      _log('开始获取 $total 个课程题目 (过滤前 ${courses.length})');
    } else {
      _log('开始获取答案, 共 $total 个课程 (过滤前 ${courses.length})');
    }

    for (int i = 0; i < total; i++) {
      if (_cancelled) break;

      final course = filtered[i];
      final title = (course['title'] ?? course['taskTitle'] ?? '未知课程')
          .toString();
      _log('[${i + 1}/$total] $title');

      onItemUpdate?.call(
        i,
        TaskProgressItem(
          title: title,
          state: PlaybackState.playing,
          progress: 0.1,
          message: '解析 paperId...',
        ),
      );

      try {
        final result = await _fetchAnswers(
          course,
          homeworkId: homeworkId,
          schoolId: schoolId,
          method: method,
          analysisWorkers: analysisWorkers,
        );

        if (result != null) {
          results.add(result);
          _log(
            '  ✓ ${result.successCount}/${result.totalCount} 道题答案',
            level: LogLevel.success,
          );
          onItemUpdate?.call(
            i,
            TaskProgressItem(
              title: title,
              state: PlaybackState.completed,
              progress: 1.0,
              message: '${result.successCount}/${result.totalCount} 道题',
            ),
          );
        } else {
          _log('  ✗ 未获取到答案', level: LogLevel.warning);
          onItemUpdate?.call(
            i,
            TaskProgressItem(
              title: title,
              state: PlaybackState.failed,
              progress: 1.0,
              error: '未获取到答案',
            ),
          );
        }
      } catch (e) {
        _log('  ✗ 异常: $e', level: LogLevel.error);
        onItemUpdate?.call(
          i,
          TaskProgressItem(
            title: title,
            state: PlaybackState.failed,
            progress: 1.0,
            error: '$e',
          ),
        );
      }

      // 请求间隔 (提交试卷场景固定 1s)
      await Future.delayed(courseInterval);
    }

    _log(
      '获取完成: ${results.length}/$total 个课程',
      level: results.length == total ? LogLevel.success : LogLevel.warning,
    );
    return results;
  }

  /// 应用过滤配置 (对应 Python my_tasks.py _apply_answer_filter)
  ///
  /// 过滤维度:
  /// 1. filterNoHomework: 过滤无作业课程 (无题目且无导学案,
  ///    即 itemCount/questionCount 无题且 studyGuideId 为空, 如 FM/资讯/板报)
  /// 2. filterCompleted: 过滤已完成课程 (homeworkFinishStatus / finished /
  ///    allFinished / taskStatus==30 任一命中即视为已完成)
  /// 3. selectedTypes: 过滤 contentType 不在选中列表的课程 (含 null 表示"全部")
  /// 4. selectedSubjects: 过滤学科不在选中列表的课程
  static List<Map<String, dynamic>> applyFilter(
    List<Map<String, dynamic>> courses,
    AnswerFilterConfig cfg,
  ) {
    var filtered = List<Map<String, dynamic>>.from(courses);

    // 1. 过滤无作业课程
    //    有作业 = 有题目(试卷 itemCount/questionCount>0) 或 有导学案/练习
    //      (视频课程 studyGuideId 非空, studyGuide 接口返回 studyTest.paperId/
    //      reportId, 实测 2026-08-24)
    //    无作业 = 两者皆无 (FM/资讯/板报/无导学案视频, 如 "25级新生综合素质
    //      提升方案" 中的 FM 讲次: taskId 有值但无题目/无导学案)
    if (cfg.filterNoHomework) {
      filtered = filtered.where((c) {
        // taskId 为空/0 视为无作业任务 (历史判定, 保留兼容)
        final tid = (c['taskId'] ?? '').toString();
        if (tid.isEmpty || tid == '0') return false;
        // 试卷题数
        final itemCount = _toIntSafe(c['itemCount']);
        final questionCount = _toIntSafe(c['questionCount']);
        if (itemCount > 0 || questionCount > 0) return true;
        // 导学案/练习 (视频课程挂载的作业)
        final sgId = (c['studyGuideId'] ?? '').toString();
        if (sgId.isNotEmpty && sgId != '0' && sgId != 'null') return true;
        return false;
      }).toList();
    }

    // 2. 过滤已完成课程
    //    完成状态字段来源多样, 需全部识别 (2026-08-24 实测 pageHomeworkTasks):
    //    - homeworkFinishStatus: homework 页 studyGuide 合并写入 (studyTest/
    //      practiceSheet.finishStatus), 批量任务路径无此字段
    //    - finished / allFinished: pageHomeworkTasks 原始返回 (服务端综合判定,
    //      对视频/试卷均准确), 批量任务课程直接携带
    //    - taskStatus == 30: 任务状态"观看完成" (对齐 ProgressReportService 判定)
    if (cfg.filterCompleted) {
      filtered = filtered.where((c) {
        bool isDone = false;
        final hfs = c['homeworkFinishStatus'];
        if (hfs == 1 || hfs == true) isDone = true;
        final finished = c['finished'];
        if (finished == true || finished == 1) isDone = true;
        final allFinished = c['allFinished'];
        if (allFinished == true || allFinished == 1) isDone = true;
        final taskStatus = c['taskStatus'];
        if (taskStatus == 30) isDone = true;
        return !isDone;
      }).toList();
    }

    // 3. 过滤课程类型 (selectedTypes 含 null 表示"全部", 不过滤)
    if (!cfg.selectedTypes.contains(null)) {
      final allowed = cfg.selectedTypes
          .where((t) => t != null)
          .map((t) => int.tryParse(t.toString()) ?? 0)
          .toSet();
      filtered = filtered.where((c) {
        final ct = c['contentType'] ?? c['content_type'];
        if (ct == null) return false;
        final ctInt = int.tryParse(ct.toString());
        return ctInt != null && allowed.contains(ctInt);
      }).toList();
    }

    // 4. 过滤课程学科
    //    主判断: subjectName 精确匹配
    //    备用判断: subjectId 反查 kSubjectIdToName 后匹配
    if (cfg.selectedSubjects.isNotEmpty) {
      final allowed = cfg.selectedSubjects.toSet();
      filtered = filtered.where((c) {
        // 主判断: subjectName / subject 字段
        final subj = c['subjectName'] ?? c['subject'];
        if (subj != null && allowed.contains(subj.toString())) {
          return true;
        }
        // 备用判断: subjectId 反查
        final subjectIdRaw = c['subjectId'];
        if (subjectIdRaw != null) {
          final sid = int.tryParse(subjectIdRaw.toString());
          if (sid != null) {
            final name = kSubjectIdToName[sid];
            if (name != null && allowed.contains(name)) return true;
          }
        }
        return false;
      }).toList();
    }

    return filtered;
  }

  /// 安全解析字段为 int (兼容 num/数字字符串/null)
  static int _toIntSafe(dynamic v) {
    if (v is num) return v.toInt();
    final s = v?.toString() ?? '';
    return int.tryParse(s) ?? 0;
  }

  /// 获取单个课程的答案
  Future<CourseAnswerResult?> _fetchAnswers(
    Map<String, dynamic> course, {
    required String homeworkId,
    required String schoolId,
    required String method,
    int analysisWorkers = _kMaxAnalysisWorkers,
  }) async {
    final contentType = _parseContentType(course);
    final title = (course['title'] ?? course['taskTitle'] ?? '').toString();
    final dayId = (course['dayId'] ?? course['day_id'] ?? '').toString();
    final subjectName = (course['subjectName'] ?? course['subject'] ?? '')
        .toString();

    // 1. 解析 paperId
    String paperId = '';
    String reportId = '';

    // contentType=2 (试卷): paperId 可能在 course 直接字段、contentUrl 或 paperContentUrl 中
    if (contentType == 2) {
      // 优先: 直接字段 (周培优任务自带 paperId)
      final directPaperId = (course['paperId'] ?? '').toString();
      if (directPaperId.isNotEmpty && directPaperId != '0') {
        paperId = directPaperId;
      }
      // 回退: 从 contentUrl / paperContentUrl 中提取 paperId 参数
      if (paperId.isEmpty) {
        final contentUrl =
            (course['contentUrl'] ??
                    course['content_url'] ??
                    course['paperContentUrl'] ??
                    '')
                .toString();
        paperId = extractPaperId(contentUrl);
      }
      reportId = (course['reportId'] ?? course['report_id'] ?? '').toString();
      if (reportId == '0') reportId = '';
      if (paperId.isNotEmpty) {
        _log('  试卷课程: paperId=$paperId');
      }
    }

    // 回退: 先调 studyGuide (主方案, 同时返回 paperId + reportId),
    // 仅当 studyGuide 失败时才调 getLessonDetailV2 (回退方案, 仅返回 paperId)。
    // 改回串行而非并发: studyGuide 成功率高, 成功时无需调 getLessonDetailV2,
    // 避免不必要的 API 调用和潜在的 URI 编码异常 (lessonId 含特殊字符时)。
    if (paperId.isEmpty) {
      _log('  尝试 studyGuide 接口...');
      final studyGuideResult = await _fetchFromStudyGuide(
        course,
        homeworkId,
        schoolId,
      );
      if (studyGuideResult.$1.isNotEmpty) {
        paperId = studyGuideResult.$1;
        reportId = studyGuideResult.$2;
      }
    }

    // 回退: getLessonDetailV2 (仅当 studyGuide 仍未获取到 paperId)
    if (paperId.isEmpty) {
      _log('  尝试 getLessonDetailV2...');
      paperId = await _fetchFromLessonDetail(course, homeworkId, schoolId);
    }

    if (paperId.isEmpty) {
      _log('  未找到 paperId', level: LogLevel.warning);
      return null;
    }

    // 2. 根据方案获取答案
    //    - auto 方案: 按优先级依次尝试 escalation → favorites → direct,
    //      任一方案成功 (successCount > 0) 即停止, 失败自动回退到下一方案。
    //    - 其他方案 (direct/escalation/favorites): 仅尝试单一方案, 不回退。
    CourseAnswerResult? result;
    if (method == 'auto') {
      // 自动方案: 多方案回退 (风控隐藏的方案自动从链中剔除,
      // 与弹窗 answer_method.* 显示控制保持一致; 全部被隐藏时回退全链)
      final visibleOrder = const ['escalation', 'favorites', 'direct']
          .where((m) => RiskControlGate.isFeatureEnabled('answer_method.$m'))
          .toList();
      final autoOrder = visibleOrder.isNotEmpty
          ? visibleOrder
          : const ['escalation', 'favorites', 'direct'];
      for (int mi = 0; mi < autoOrder.length; mi++) {
        if (_cancelled) break;
        final m = autoOrder[mi];
        if (mi > 0) {
          _log('  自动方案: 当前方式未成功, 自动切换...', level: LogLevel.warning);
        }
        if (m == 'escalation') {
          result = await _fetchViaEscalation(
            title,
            paperId,
            reportId,
            homeworkId,
            analysisWorkers: analysisWorkers,
          );
        } else if (m == 'favorites') {
          result = await _fetchViaFavorites(
            title,
            paperId,
            reportId,
            homeworkId,
            course,
          );
        } else {
          result = await _fetchDirect(
            title,
            paperId,
            reportId,
            homeworkId,
            analysisWorkers: analysisWorkers,
          );
        }
        if (result != null && result.successCount > 0) break;
        // result 为 null 或 0 题成功: 尝试下一个方案
        if (mi < autoOrder.length - 1 &&
            result != null &&
            result.successCount == 0) {
          _log('  $m 方案获取 0 题, 尝试下一个方案', level: LogLevel.warning);
        }
      }
    } else if (method == 'escalation') {
      result = await _fetchViaEscalation(
        title,
        paperId,
        reportId,
        homeworkId,
        analysisWorkers: analysisWorkers,
      );
    } else if (method == 'favorites') {
      result = await _fetchViaFavorites(
        title,
        paperId,
        reportId,
        homeworkId,
        course,
      );
    } else if (method == 'questions') {
      // 提交试卷专属: 独立取题路径, 用页面真实 reportId 一次拉取整卷题目,
      // 不走逐题 getQuestionAnalysis 的答案获取路径。
      result = await _fetchQuestionsOnly(
        title,
        paperId,
        reportId,
        homeworkId,
        course,
      );
    } else {
      result = await _fetchDirect(
        title,
        paperId,
        reportId,
        homeworkId,
        analysisWorkers: analysisWorkers,
      );
    }

    // 3. 填充 dayId/dateLabel/subjectName (对应 Python answer_data.day_id/date_label)
    // 始终填充: 即使 dayId/subjectName 为空也要覆盖 result 中的默认空值
    if (result != null) {
      // dayId 为空时回退到当前日期, 确保 {课程日期} 占位符不会为空
      final effectiveDayId = dayId.isNotEmpty ? dayId : _todayStr();
      // dateLabel 优先取 homework_provider 注入的日期筛选栏日期 (如 "3月15日"),
      // 其次回退到 dayId, 最后回退到当前日期
      final injectedDateLabel = (course['dateLabel'] ?? '').toString();
      final effectiveDateLabel = injectedDateLabel.isNotEmpty
          ? injectedDateLabel
          : (dayId.isNotEmpty ? dayId : _todayStr());

      // 提交参数优先使用课程的页面原始值:
      // 课程 contentType=2 时 contentUrl/reportId 来自真实答题页面 URL,
      // 对应 Web 页面报告 (如 bizCode=205&reportId=xxx&homeworkId=xxx)。
      // reportId 方案 (201) 获取答案时会生成独立的越权报告,
      // 若用该报告提交, 保存不会出现在真实答题页面, 刷新看不到进度。
      // 因此从 contentUrl / 课程字段解析页面参数, 覆盖 result 中的越权值。
      final contentUrl = (course['contentUrl'] ?? course['content_url'] ?? '')
          .toString();
      // 从页面 URL 一次性解析所有参数 (避免重复 split + parseQueryString)
      // 页面 URL 参数最可靠, 优先级高于课程自带字段和 result 中的越权值
      final pageParams = _parseUrlParams(contentUrl);
      final pageParamReportId = pageParams['reportId'] ?? '';
      final pageParamBizCode = pageParams['bizCode'] ?? '';
      final pageParamHomeworkId = pageParams['homeworkId'] ?? '';
      var pageReportId = pageParamReportId.isNotEmpty
          ? pageParamReportId
          : (reportId.isNotEmpty ? reportId : result.reportId);
      final courseBizCode = (course['bizCode'] ?? course['biz_code'] ?? '')
          .toString();
      final pageBizCode = pageParamBizCode.isNotEmpty
          ? pageParamBizCode
          : (courseBizCode.isNotEmpty ? courseBizCode : result.bizCode);
      // 实际作业 ID: 优先页面 URL, 其次课程自带, 再其次 result/executeBatch
      final courseHwId = (course['homeworkId'] ?? course['homework_id'] ?? '')
          .toString();
      final pageHomeworkId = pageParamHomeworkId.isNotEmpty
          ? pageParamHomeworkId
          : (courseHwId.isNotEmpty
                ? courseHwId
                : (result.homeworkId.isNotEmpty
                      ? result.homeworkId
                      : homeworkId));

      // 205 试卷无页面 reportId 时, 模拟 answer-pc 打开页面的跳转获取真实 reportId:
      // 地址栏 reportId 是 answer-pc 内部调 report(bizCode=205, homeworkId=真实值)
      // 后追加的, 越权查询用的 reportId (201/205+homeworkId='0') 是独立报告,
      // 直接用于提交会导致保存到错误报告 (错误提交/刷新看不到进度)。
      // 实测 report(205, 真实 homeworkId) 返回的 reportId 与跳转后地址栏完全一致。
      if (pageBizCode == '205' &&
          pageHomeworkId.isNotEmpty &&
          (pageReportId.isEmpty || pageReportId == '0')) {
        try {
          final realReport = await _answerRemote.getAnswerReport(
            paperId: result.paperId,
            bizCode: '205',
            homeworkId: pageHomeworkId,
          );
          if (realReport['success'] == true) {
            final realData = realReport['data'];
            if (realData is Map<String, dynamic>) {
              final realRid = (realData['reportId'] ?? '').toString();
              if (realRid.isNotEmpty && realRid != '0') {
                _log(
                  '  205 试卷无页面 reportId, 模拟页面跳转获取真实 reportId: '
                  '$realRid (原 ${pageReportId.isEmpty ? '空' : pageReportId})',
                );
                pageReportId = realRid;
              }
            }
          } else {
            _log(
              '  获取 205 真实 reportId 失败: '
              '${realReport['message'] ?? '未知错误'}',
              level: LogLevel.warning,
            );
          }
        } catch (e) {
          _log('  获取 205 真实 reportId 异常: $e', level: LogLevel.warning);
        }
      }

      return CourseAnswerResult(
        courseTitle: result.courseTitle,
        method: result.method,
        paperId: result.paperId,
        questions: result.questions,
        successCount: result.successCount,
        totalCount: result.totalCount,
        dayId: effectiveDayId,
        dateLabel: effectiveDateLabel,
        subjectName: subjectName,
        reportId: pageReportId,
        bizCode: pageBizCode,
        homeworkId: pageHomeworkId,
        platform: result.platform,
        assignPoints: result.assignPoints,
        paperPackageId: result.paperPackageId,
        userId: result.userId,
      );
    }
    return result;
  }

  /// 直接获取 (bizCode=204)
  ///
  /// 对应 Python: course_batch.py _fetch_answers_direct
  Future<CourseAnswerResult?> _fetchDirect(
    String courseTitle,
    String paperId,
    String reportId,
    String homeworkId, {
    int analysisWorkers = _kMaxAnalysisWorkers,
  }) async {
    // 优先: answer/paper 一次获取完整题目列表
    List<Map<String, dynamic>> questionList = [];
    try {
      final paperResult = await _answerRemote.getAnswerPaper(
        paperId: paperId,
        reportId: reportId,
        bizCode: '204',
      );
      if (paperResult['success'] == true) {
        final data = paperResult['data'];
        if (data is Map<String, dynamic>) {
          final questions = (data['questions'] as List<dynamic>?) ?? [];
          questionList = questions.whereType<Map<String, dynamic>>().toList();
          _log('  answer/paper: ${questionList.length} 题');
        }
      }
    } catch (e) {
      _log('  answer/paper 失败: $e, 回退 getPaperQuestionByPaperId');
    }

    // 回退: getPaperQuestionByPaperId
    if (questionList.isEmpty) {
      try {
        final fallback = await _answerRemote.getPaperQuestions(
          paperId: paperId,
        );
        if (fallback['success'] == true) {
          final data = fallback['data'];
          if (data is Map<String, dynamic>) {
            final rawList = (data['questionList'] as List<dynamic>?) ?? [];
            // 保留完整字段 (questionContent/options/childQuestions 等),
            // 不再精简为仅 id/number/group, 否则题干和选项会全部丢失
            questionList = rawList.whereType<Map<String, dynamic>>().toList();
            _log('  getPaperQuestionByPaperId: ${questionList.length} 题');
          }
        }
      } catch (e) {
        _log('  getPaperQuestionByPaperId 失败: $e', level: LogLevel.error);
      }
    }

    if (questionList.isEmpty) return null;

    // 提取答案
    final collected = <QuestionInfo>[];
    final needAnalysis = <Map<String, dynamic>>[];

    for (final q in questionList) {
      if (_cancelled) break;
      final qid = (q['id'] ?? q['questionId'] ?? '').toString();
      if (qid.isEmpty) continue;

      final number = (q['questionNoShow'] ?? q['questionNumber'] ?? '')
          .toString();
      final group = (q['groupName'] ?? '').toString();
      final childQuestions = (q['childQuestions'] as List<dynamic>?) ?? [];

      if (childQuestions.isNotEmpty) {
        // 分组题: 递归提取
        final info = QuestionInfo.fromJson(q, number: number, group: group);
        final hasEmpty = info.childQuestions.any(
          (cq) => cq.answer.isEmpty || cq.answer == '(主观题)',
        );
        if (hasEmpty) {
          needAnalysis.add({'qid': qid, 'info': info, 'isParent': true});
        } else {
          collected.add(info);
        }
      } else {
        // 普通题
        final info = QuestionInfo.fromJson(q, number: number, group: group);
        if (info.answer.isNotEmpty && info.answer != '(主观题)') {
          collected.add(info);
        } else {
          needAnalysis.add({
            'qid': qid,
            'number': number,
            'group': group,
            'isParent': false,
            'info': info, // 保存已解析的题干, 补全失败时恢复
          });
        }
      }
    }

    // 逐题查询答案为空的题目 (analysisWorkers=1 时即串行, 不并发)
    if (needAnalysis.isNotEmpty) {
      if (analysisWorkers > 1) {
        _log('  ${needAnalysis.length} 题答案为空, 并发查询 (max $analysisWorkers)...');
      } else {
        _log('  ${needAnalysis.length} 题答案为空, 逐题查询...');
      }
      final results =
          await _runConcurrentNullable<Map<String, dynamic>, QuestionInfo>(
            needAnalysis,
            analysisWorkers,
            (item) => _fetchDirectSingleAnalysis(
              item,
              paperId: paperId,
              reportId: reportId,
              homeworkId: homeworkId,
            ),
          );
      // 并发结果按原顺序追加 (含补全成功和失败回退的题目)
      for (final r in results) {
        if (r != null) collected.add(r);
      }
    }

    return CourseAnswerResult(
      courseTitle: courseTitle,
      method: 'direct',
      paperId: paperId,
      questions: collected,
      successCount: collected.length,
      totalCount: questionList.length,
      reportId: reportId,
      bizCode: '204',
      homeworkId: homeworkId,
      platform: '1',
    );
  }

  /// 提交试卷专属 — 独立取题路径 (method='questions')
  ///
  /// 不走答案获取路径 (不做逐题 getQuestionAnalysis):
  /// 仅用页面真实的 reportId/bizCode/homeworkId 调 paperQuestionGroup,
  /// 一次拉取整卷题目 (题干/选项/子题/主观题标记), 供手动填写提交。
  ///
  /// 流程:
  /// 1. 从课程 contentUrl / 字段解析页面取题参数 (reportId/bizCode/homeworkId);
  ///    205 试卷状态栏无 reportId 时, 模拟 answer-pc 打开页面的跳转,
  ///    调 report(205, 真实 homeworkId) 获取真实 reportId。
  /// 2. 调 paperQuestionGroup 整卷取题; 失败回退 getPaperQuestionByPaperId
  ///    (同为单次请求, 保留完整题干/选项/子题)。
  /// 3. 解析为 [QuestionInfo], 不调用 getQuestionAnalysis, 答案栏为空,
  ///    由用户手动填写。
  Future<CourseAnswerResult?> _fetchQuestionsOnly(
    String courseTitle,
    String paperId,
    String reportId, // 已解析的兜底 reportId (course字段/studyGuide) 可为空
    String homeworkId, // 已解析的兜底 homeworkId 可为空
    Map<String, dynamic> course,
  ) async {
    // 1. 解析页面真实取题参数
    final contentUrl = (course['contentUrl'] ?? course['content_url'] ?? '')
        .toString();
    final pageParams = _parseUrlParams(contentUrl);
    final courseBizCode = (course['bizCode'] ?? course['biz_code'] ?? '')
        .toString();
    final pageBizCode = (pageParams['bizCode'] ?? '').isNotEmpty
        ? pageParams['bizCode']!
        : (courseBizCode.isNotEmpty ? courseBizCode : '205');
    final courseHwId = (course['homeworkId'] ?? course['homework_id'] ?? '')
        .toString();
    final pageHomeworkId = (pageParams['homeworkId'] ?? '').isNotEmpty
        ? pageParams['homeworkId']!
        : (courseHwId.isNotEmpty ? courseHwId : homeworkId);
    var pageReportId = (pageParams['reportId'] ?? '').isNotEmpty
        ? pageParams['reportId']!
        : (course['reportId'] ?? course['report_id'] ?? reportId).toString();
    if (pageReportId == '0') pageReportId = '';

    // 试卷无页面 reportId: 模拟 answer-pc 打开页面时的 report 调用获取真实 reportId。
    // 对齐真实流程 (edge-devtools 实测):
    //   - bizCode=205: report 需真实 homeworkId (extId/homeworkId), 页面 URL 一般已带 reportId
    //   - bizCode=204: 页面 URL 无 reportId (仅 isRepeat=1), report(bizCode=204) 返回真实 reportId
    // paperQuestionGroup 依赖真实 reportId, 缺失时返回 success=false, 故必须先解析。
    if (pageReportId.isEmpty &&
        ((pageBizCode == '205' && pageHomeworkId.isNotEmpty) ||
            pageBizCode == '204')) {
      try {
        final rr = await _answerRemote.getAnswerReport(
          paperId: paperId,
          bizCode: pageBizCode,
          homeworkId: pageHomeworkId,
        );
        if (rr['success'] == true && rr['data'] is Map<String, dynamic>) {
          final rid = (rr['data']['reportId'] ?? '').toString();
          if (rid.isNotEmpty && rid != '0') {
            _log('  $pageBizCode 试卷无页面 reportId, 模拟页面打开获取真实 reportId: $rid');
            pageReportId = rid;
          }
        }
      } catch (_) {}
    }

    final userId = await _getUserIdCached();

    // 2. 整卷取题 (paperQuestionGroup → 回退 getPaperQuestionByPaperId)
    List<Map<String, dynamic>> questions = [];
    try {
      final res = await _answerRemote.getPaperQuestionGroup(
        paperId: paperId,
        reportId: pageReportId,
        bizCode: pageBizCode,
        userId: userId,
        homeworkId: pageHomeworkId,
      );
      if (res['success'] == true) {
        final data = res['data'];
        if (data is Map<String, dynamic>) {
          for (final g in (data['groups'] as List<dynamic>?) ?? []) {
            if (g is! Map<String, dynamic>) continue;
            final groupName = (g['groupName'] ?? '').toString();
            for (final q in (g['questions'] as List<dynamic>?) ?? []) {
              if (q is! Map<String, dynamic>) continue;
              // 分组题: 使用题组名兜底 (单个题目可能未带 groupName)
              final qGroup = (q['groupName'] ?? '').toString();
              q['groupName'] = qGroup.isNotEmpty ? qGroup : groupName;
              questions.add(q);
            }
          }
        }
        if (questions.isNotEmpty) {
          _log('  paperQuestionGroup: ${questions.length} 题');
        }
      } else {
        _log(
          '  paperQuestionGroup 失败: ${res['message'] ?? '未知错误'}, '
          '回退 getPaperQuestionByPaperId',
          level: LogLevel.warning,
        );
      }
    } catch (e) {
      _log(
        '  paperQuestionGroup 异常: $e, 回退 getPaperQuestionByPaperId',
        level: LogLevel.warning,
      );
    }

    if (questions.isEmpty) {
      try {
        final fb = await _answerRemote.getPaperQuestions(paperId: paperId);
        if (fb['success'] == true && fb['data'] is Map<String, dynamic>) {
          final rawList = (fb['data']['questionList'] as List<dynamic>?) ?? [];
          questions = rawList.whereType<Map<String, dynamic>>().toList();
          if (questions.isNotEmpty) {
            _log('  getPaperQuestionByPaperId: ${questions.length} 题');
          }
        }
      } catch (e) {
        _log('  getPaperQuestionByPaperId 失败: $e', level: LogLevel.error);
      }
    }

    if (questions.isEmpty) return null;

    // 3. 解析为 QuestionInfo (不逐题查询, 答案栏为空交给手动填写)
    final collected = <QuestionInfo>[];
    for (final q in questions) {
      if (_cancelled) break;
      final qid = (q['id'] ?? q['questionId'] ?? '').toString();
      if (qid.isEmpty) continue;
      final number = (q['questionNoShow'] ?? q['questionNumber'] ?? '')
          .toString();
      final group = (q['groupName'] ?? '').toString();
      collected.add(QuestionInfo.fromJson(q, number: number, group: group));
    }

    return CourseAnswerResult(
      courseTitle: courseTitle,
      method: 'questions',
      paperId: paperId,
      questions: collected,
      successCount: collected.length,
      totalCount: questions.length,
      reportId: pageReportId,
      bizCode: pageBizCode,
      homeworkId: pageHomeworkId,
      platform: '1',
      userId: userId,
    );
  }

  /// reportId 方案 (默认 bizCode=201, ewt.js 同款越权方案; 205 试卷回退)
  ///
  /// 对应 Python: course_batch.py _fetch_answers_via_reportid
  /// 参考: GetEWTAnswers-main/ewt.js (zhicheng233)
  ///
  /// 关键: 所有 API 调用强制使用 homeworkId='0', 不传入实际 homeworkId。
  /// 这是越权方案的核心 — 服务端将请求视为非关联作业的通用查询,
  /// 从而绕过作业归属检查, 允许获取任意试卷的答案。
  ///
  /// 流程:
  ///   1. getAnswerReport(bizCode=201) 获取 reportId; 失败回退 205
  ///   2. getAnswerSheetSubGroup 获取题目列表, 失败回退 answerSheetInfo (需 userId)
  ///   3. submitPaper(homeworkId='0') 提交报告 (解锁答案查询) — 仅 201 链,
  ///      205 链严禁 submitPaper (会把真实试卷空提交/关闭当前报告)
  ///   4. 逐题 getQuestionAnalysis(bizCode, homeworkId='0') 获取 rightAnswer/analyse/knowledges
  ///
  /// 205 回退说明 (实测 8月9日 测一测专题测试卷, 201/204 均返回 reportId=null):
  /// - 已完成的试卷: 调用方传入的 reportId (任务列表完成报告) 已解锁,
  ///   直接 sheet + analysis 获取答案, 零副作用
  /// - 未完成的试卷: report(205) 返回当前报告但未解锁, analysis 返回空答案
  ///   (锁定), 判为失败 — 严禁用 submitPaper 解锁 (等于真实交卷)
  /// - 提交做题痕迹/交卷走 answer_submit_service 的"模拟 answer-pc 跳转"
  ///   获取真实报告, 绝不使用本链的查询 reportId
  Future<CourseAnswerResult?> _fetchViaEscalation(
    String courseTitle,
    String paperId,
    String reportId,
    String homeworkId, {
    int analysisWorkers = _kMaxAnalysisWorkers,
  }) async {
    // 越权方案核心: 所有步骤强制 homeworkId='0' (对齐 HAR + ewt.js)
    // 传入真实 homeworkId 会导致 submitpaper "交卷失败" → reportId 未激活 →
    // 后续 getQuestionAnalysis "参数不合法"
    const hwId = '0';

    // 1. 获取 reportId — 优先纯 bizCode=201 (对齐 ewt.js getReportId(BIZ_VIEW))
    //
    // 对齐 debug/GetEWTAnswers/ewt.js:
    //   - 全程使用 BIZ_VIEW='201'
    //   - 必须重新获取: studyGuide 返回的 reportId 是旧的, submitpaper 用旧
    //     reportId 会 "交卷失败" → 后续 analysis "参数不合法"
    //
    // 201 返回 reportId=null 时回退 bizCode=205:
    //   对齐 Web: 任务列表 contentUrl 为 mystudy/#/exam/answer?bizCode=205&
    //   homeworkId=xxx, 由 report(205) 换取 reportId 后再进 answer-pc。
    String rid = '';
    String usedBizCode = '201';
    for (final candidate in ['201', '205']) {
      if (rid.isNotEmpty) break;
      try {
        final reportResult = await _answerRemote.getAnswerReport(
          paperId: paperId,
          bizCode: candidate,
          homeworkId: hwId,
        );
        if (reportResult['success'] == true) {
          final data = reportResult['data'];
          if (data is Map<String, dynamic>) {
            rid = (data['reportId'] ?? '').toString();
          }
          if (rid.isNotEmpty) {
            usedBizCode = candidate;
            _log('  getReportId($candidate) 成功: reportId=$rid');
          }
        } else {
          _log(
            '  getReportId($candidate) 失败: '
            '${reportResult['message'] ?? '未知错误'}',
            level: LogLevel.warning,
          );
        }
      } catch (e) {
        _log('  getReportId($candidate) 异常: $e', level: LogLevel.warning);
      }
    }

    // 205 试卷: 调用方传入的 reportId (任务列表完成报告/页面 URL 报告) 已解锁,
    // 优先直接使用, 不重新获取 (report(205) 返回的是当前可作答报告, 未解锁)。
    if (usedBizCode != '205' &&
        rid.isEmpty &&
        reportId.isNotEmpty &&
        reportId != '0') {
      rid = reportId;
      usedBizCode = '205';
      _log('  205 试卷使用传入 reportId (可能为完成报告): $rid');
    }

    if (rid.isEmpty) {
      // 201/205 均失败说明试卷不支持 reportId 越权方案 (已提交/已完成/已过期 等),
      // 返回 null 由自动方案回退到 favorites/direct
      _log(
        '  无法获取必要凭证 (201/205), 该试卷可能不支持当前获取方式',
        level: LogLevel.warning,
      );
      return null;
    }
    _log('  paperId=$paperId, bizCode=$usedBizCode, reportId=$rid');

    // 2. 获取题目列表 (bizCode=usedBizCode) — ewt.js getQuestions
    final questions = <Map<String, dynamic>>[];
    try {
      final sheetResult = await _answerRemote.getAnswerSheetSubGroup(
        paperId: paperId,
        reportId: rid,
        homeworkId: hwId,
        bizCode: usedBizCode,
      );
      if (sheetResult['success'] == true) {
        final data = sheetResult['data'];
        if (data is Map<String, dynamic>) {
          for (final group
              in (data['groupQuestionList'] as List<dynamic>?) ?? []) {
            if (group is Map<String, dynamic>) {
              final groupName = (group['groupName'] ?? '').toString();
              for (final q in (group['questionList'] as List<dynamic>?) ?? []) {
                if (q is Map<String, dynamic>) {
                  // 保留 cateId/subjective 对齐 Python (目前未使用, 预留扩展)
                  questions.add({
                    'questionId': q['questionId'],
                    'questionNumber': q['questionNumber'],
                    'groupName': groupName,
                    'cateId': q['cateId'] ?? 1,
                    'subjective': q['subjective'] ?? false,
                  });
                }
              }
            }
          }
        }
      } else {
        _log(
          '  answerSheetSubGroup 失败: ${sheetResult['message'] ?? '未知'}, 回退 answerSheetInfo',
          level: LogLevel.warning,
        );
      }
    } catch (e) {
      _log(
        '  answerSheetSubGroup 异常: $e, 回退 answerSheetInfo',
        level: LogLevel.warning,
      );
    }

    // 回退: answerSheetInfo (需 userId) — ewt.js getQuestions 失败分支
    if (questions.isEmpty) {
      try {
        final userId = await _getUserIdCached();
        final infoResult = await _answerRemote.getAnswerSheetInfo(
          paperId: paperId,
          reportId: rid,
          userId: userId,
          homeworkId: hwId,
          bizCode: usedBizCode,
        );
        if (infoResult['success'] == true) {
          final data = infoResult['data'];
          if (data is Map<String, dynamic>) {
            for (final q
                in (data['questionInfoList'] as List<dynamic>?) ?? []) {
              if (q is Map<String, dynamic>) {
                questions.add({
                  'questionId': q['questionId'],
                  'questionNumber': q['questionNumber'],
                  'groupName': '',
                  'cateId': q['cateId'] ?? 1,
                  'subjective': q['subjective'] ?? false,
                });
              }
            }
          }
        } else {
          _log(
            '  answerSheetInfo 失败: ${infoResult['message'] ?? '未知错误'}',
            level: LogLevel.error,
          );
        }
      } catch (e) {
        _log('  answerSheetInfo 异常: $e', level: LogLevel.error);
      }
    }

    if (questions.isEmpty) {
      _log('  未找到题目', level: LogLevel.warning);
      return null;
    }
    _log('  题目列表: ${questions.length} 题');

    // 3. submitPaper 解锁答案查询 (对齐 ewt.js updateReport) — 仅 201 链
    //
    // 对齐 debug/GetEWTAnswers/ewt.js:
    //   - updateReport(body={paperId, reportId, bizCode, platform, totalSeconds:600, homeworkId:'0'})
    //   - homeworkId='0' 是越权方案核心: 服务端将请求视为非关联作业的通用查询,
    //     不会真的提交到作业, 避免污染真实答题页面进度
    //   - submitPaper 后, getQuestionAnalysis 才能返回 rightAnswer/analyse
    //     (未解锁前返回空数组, 导致答案栏显示 [])
    //
    // 205 链严禁 submitPaper (实测 205 卷 report(205) 返回真实报告,
    // submitPaper 会把真实试卷空提交并关闭当前报告, 任务列表显示已交卷)。
    // 205 已完成的试卷 (任务列表完成报告) 天然已解锁, 无需解锁;
    // 未完成的 205 试卷保持锁定, analysis 返回空答案, 判为获取失败。
    if (usedBizCode == '201') {
      _log('  执行 submitPaper (解锁答案查询)...');
      try {
        final submitResult = await _answerRemote.submitPaper(
          paperId: paperId,
          reportId: rid,
          homeworkId: hwId,
          bizCode: '201',
        );
        _log(
          '  submitpaper success=${submitResult['success'] == true}, '
          'msg=${submitResult['message'] ?? ''}',
        );
      } catch (e) {
        _log('  submitpaper 异常: $e (继续尝试获取答案)', level: LogLevel.warning);
      }
    } else {
      _log('  205 链跳过 submitPaper (避免真实试卷被空提交/关闭当前报告)');
    }

    // 4. 所有题目统一走 getQuestionAnalysis (对齐 ewt.js 逐题 getAnswer)
    //
    // 对齐 debug/GetEWTAnswers/ewt.js:
    //   - 不预取 getAnswerPaper(204), 该接口在 reportId 方案中不可靠:
    //     * 未解锁时返回 rightAnswer=[] (被 _formatAnswer 误判为有答案 "[]")
    //     * 204 创建的 reportId 与 201 的 getQuestionAnalysis 不兼容
    //   - ewt.js 直接 for (q of questions) getAnswer(rid, qid, 201)
    //   - 205 回退时逐题查询同样使用 bizCode=205 (实测 201 报"参数不合法");
    //     未完成试卷的 205 报告未解锁, analysis 返回空答案, worker 判为锁定
    //   - 并发工作线程 (max _kMaxAnalysisWorkers) 替代 ewt.js 的串行, 提升大批量试卷速度
    final needAnalysis = <Map<String, dynamic>>[];
    for (final q in questions) {
      if (_cancelled) break;
      final qid = (q['questionId'] ?? '').toString();
      if (qid.isEmpty) continue;
      needAnalysis.add({
        'qid': qid,
        'number': (q['questionNumber'] ?? '').toString(),
        'group': (q['groupName'] ?? '').toString(),
        'meta': q,
      });
    }

    final collected = <QuestionInfo>[];
    int failCount = 0;
    if (needAnalysis.isNotEmpty) {
      _log(
        analysisWorkers > 1
            ? '  ${needAnalysis.length} 题逐题查询, 并发 (max $analysisWorkers)...'
            : '  ${needAnalysis.length} 题逐题查询...',
      );
      final results =
          await _runConcurrentNullable<Map<String, dynamic>, QuestionInfo>(
            needAnalysis,
            analysisWorkers,
            (item) => _fetchAndMergeAnalysis(
              item,
              paperId: paperId,
              reportId: rid,
              homeworkId: hwId,
              bizCode: usedBizCode,
            ),
          );
      for (final r in results) {
        if (r != null) {
          collected.add(r);
        } else {
          failCount++;
        }
      }
    }

    if (failCount > 0) {
      _log(
        '  reportId 方案: $failCount/${questions.length} 题答案获取失败',
        level: LogLevel.warning,
      );
    }

    return CourseAnswerResult(
      courseTitle: courseTitle,
      method: 'escalation',
      paperId: paperId,
      questions: collected,
      successCount: collected.length,
      totalCount: questions.length,
      reportId: rid,
      bizCode: usedBizCode,
      // 保存真实 homeworkId 供提交使用 (API 调用仍用 hwId='0' 越权)
      homeworkId: homeworkId,
      platform: '1',
    );
  }

  /// 收藏夹机制获取
  ///
  /// 对应 Python: course_batch.py _fetch_answers_via_favorites
  /// 流程: getPaperQuestions → 获取/创建 hello 收藏夹 → 并发添加题目 →
  ///       获取答案 → 并发清理
  ///
  /// 并发: 添加/清理步骤使用 [_kMaxFavWorkers] 并发 (对齐 Python MAX_FAV_WORKERS=5)
  Future<CourseAnswerResult?> _fetchViaFavorites(
    String courseTitle,
    String paperId,
    String reportId,
    String homeworkId,
    Map<String, dynamic> course,
  ) async {
    // 用于提交的有效 reportId:
    // - 课程自带的页面 reportId (contentUrl 或 studyGuide, bizCode=205/204)
    // - 为空时通过 204 获取新报告 (只能保存到独立报告, 页面可能看不到,
    //   但至少能提交成功)
    var effectiveReportId = reportId;
    if (effectiveReportId.isEmpty) {
      try {
        final reportResult = await _answerRemote.getAnswerReport(
          paperId: paperId,
          bizCode: '204',
        );
        if (reportResult['success'] == true) {
          final data = reportResult['data'];
          if (data is Map<String, dynamic>) {
            effectiveReportId = (data['reportId'] ?? '').toString();
          }
        }
        if (effectiveReportId.isEmpty) {
          _log('  备用方式: 提交时所需凭证获取失败, 将不可用', level: LogLevel.warning);
        }
      } catch (e) {
        _log('  备用方式: 凭证获取异常, 将不可用', level: LogLevel.warning);
      }
    }
    if (effectiveReportId.isEmpty) {
      _log('  备用方式: 无法获取凭证 (无法提交做题痕迹)', level: LogLevel.warning);
    }
    _log(
      '  收藏夹: reportId=${effectiveReportId.isEmpty ? '(无)' : effectiveReportId}',
    );
    // 1. 获取题目列表和 subjectId
    Map<String, dynamic>? paperData;
    try {
      final result = await _answerRemote.getPaperQuestions(paperId: paperId);
      if (result['success'] == true && result['data'] is Map<String, dynamic>) {
        paperData = result['data'] as Map<String, dynamic>;
      }
    } catch (e) {
      _log('  getPaperQuestions 失败: $e', level: LogLevel.error);
    }
    if (paperData == null) return null;

    final rawList = (paperData['questionList'] as List<dynamic>?) ?? [];
    final questionList = rawList.whereType<Map<String, dynamic>>().toList();
    if (questionList.isEmpty) return null;

    final subjectId = (paperData['subjectId'] is int)
        ? paperData['subjectId'] as int
        : int.tryParse(paperData['subjectId']?.toString() ?? '') ?? 3;
    final questionIds = questionList
        .map((q) => (q['questionId'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    if (questionIds.isEmpty) return null;

    // 实际题目数 = 顶层题 + 子题 (收藏夹方案按问题数统计)
    int countRealQuestions(List<Map<String, dynamic>> list) {
      var n = 0;
      for (final q in list) {
        final subs = (q['subQuestionList'] as List<dynamic>?) ?? [];
        n += subs.isNotEmpty ? subs.length : 1;
      }
      return n;
    }

    final realTotalCount = countRealQuestions(questionList);
    _log(
      '  收藏夹: ${questionIds.length} 顶层题 (实际 $realTotalCount 题), subjectId=$subjectId',
    );

    // 2. 获取或创建 hello 收藏夹
    dynamic labelId;
    try {
      final labelResult = await _answerRemote.getWrongQuestionLabels(subjectId);
      if (labelResult['success'] == true) {
        final labels = (labelResult['data'] as List<dynamic>?) ?? [];
        for (final label in labels) {
          if (label is Map<String, dynamic> &&
              label['title'] == AnswerRemoteDataSource.helloLabelName &&
              label['readonly'] != true) {
            labelId = label['id'];
            break;
          }
        }
      }
    } catch (_) {}

    if (labelId == null) {
      try {
        final createResult = await _answerRemote.createWrongQuestionLabel(
          subjectId,
        );
        if (createResult['success'] == true) {
          labelId = createResult['data'];
        }
      } catch (_) {}
    }
    if (labelId == null) {
      _log('  无法获取/创建收藏夹', level: LogLevel.warning);
      return null;
    }
    _log('  收藏夹 labelId=$labelId');

    // 3. 并发添加所有题目到收藏夹 (对齐 Python ThreadPoolExecutor(max_workers=5))
    final labelIds = [
      if (labelId is int) labelId else int.tryParse('$labelId') ?? 0,
    ];
    final addResults = await _runConcurrent(questionIds, _kMaxFavWorkers, (
      qid,
    ) async {
      if (_cancelled) return false;
      try {
        final r = await _answerRemote.addQuestionToLabel(
          subjectId,
          qid,
          labelIds,
        );
        return r['success'] == true;
      } catch (_) {
        return false;
      }
    });
    final addFailed = addResults.where((ok) => !ok).length;
    if (addFailed > 0) {
      _log('  $addFailed 题添加收藏夹失败', level: LogLevel.warning);
    }

    // 等待服务器索引
    await Future.delayed(const Duration(seconds: 2));

    // 4. 从收藏夹获取答案
    List<dynamic> helloQuestions = [];
    try {
      final hqResult = await _answerRemote.getQuestionsFromLabel(
        labelId,
        subjectId,
      );
      if (hqResult['success'] == true) {
        helloQuestions = (hqResult['data'] as List<dynamic>?) ?? [];
      }
    } catch (_) {}

    // 建立 questionId → {number, group} 映射
    final qidMeta = <String, (String, String)>{};
    for (final q in questionList) {
      final qid = (q['questionId'] ?? '').toString();
      qidMeta[qid] = (
        (q['questionNumber'] ?? '').toString(),
        (q['groupName'] ?? '').toString(),
      );
    }

    final collected = <QuestionInfo>[];
    for (final qid in questionIds) {
      if (_cancelled) break;
      final meta = qidMeta[qid] ?? ('', '');

      // 先从收藏夹列表匹配
      Map<String, dynamic>? matched;
      for (final hq in helloQuestions) {
        if (hq is Map<String, dynamic> && hq['questionId']?.toString() == qid) {
          matched = hq;
          break;
        }
      }

      QuestionInfo? info;
      if (matched != null) {
        info = QuestionInfo.fromJson(matched, number: meta.$1, group: meta.$2);
      }

      // 列表项无答案 (含子题答案) 时回退: 单独请求 info → analysis
      // (父题分析含 childQuestions, 子题答案在 childQuestions 中)
      bool hasAnswer(QuestionInfo? i) =>
          i != null &&
          (i.answer.isNotEmpty ||
              i.childQuestions.any((c) => c.answer.isNotEmpty));
      if (!hasAnswer(info)) {
        try {
          final infoResult = await _answerRemote.getQuestionCollectInfo(
            qid,
            subjectId,
            labelId,
          );
          if (infoResult['success'] == true &&
              infoResult['data'] is Map<String, dynamic>) {
            info = QuestionInfo.fromJson(
              infoResult['data'] as Map<String, dynamic>,
              number: meta.$1,
              group: meta.$2,
            );
          }
        } catch (_) {}

        // 还是没有答案, 尝试 analysis (父题 analysis 返回
        // childQuestions 数组含子题答案, 与 paperId 方案一致)
        if (!hasAnswer(info)) {
          try {
            final aResult = await _answerRemote.getQuestionCollectAnalysis(
              qid,
              subjectId,
              labelId,
            );
            if (aResult['success'] == true &&
                aResult['data'] is Map<String, dynamic>) {
              info = QuestionInfo.fromJson(
                aResult['data'] as Map<String, dynamic>,
                number: meta.$1,
                group: meta.$2,
              );
            }
          } catch (_) {}
        }
      }

      if (info != null) {
        // 补全子题题号 (父题-子序号), 与 reportId 方案一致
        if (info.childQuestions.isNotEmpty) {
          info = _formatChildQuestionNumbers(info, meta.$1);
        }
        if (hasAnswer(info)) {
          collected.add(info);
        }
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // 5. 并发清理收藏夹 (对齐 Python ThreadPoolExecutor(max_workers=5))
    await _runConcurrent(questionIds, _kMaxFavWorkers, (qid) async {
      if (_cancelled) return true;
      try {
        await _answerRemote.removeQuestionFromLabel(subjectId, qid);
        return true;
      } catch (_) {
        return false;
      }
    });

    // 按实际题数统计成功数 (父题含 childQuestions 时按子题数计)
    int countCollectedQuestions(List<QuestionInfo> list) {
      var n = 0;
      for (final q in list) {
        n += q.childQuestions.isNotEmpty ? q.childQuestions.length : 1;
      }
      return n;
    }

    final realSuccessCount = countCollectedQuestions(collected);
    _log('  收藏夹获取: $realSuccessCount/$realTotalCount 题');
    return CourseAnswerResult(
      courseTitle: courseTitle,
      method: 'favorites',
      paperId: paperId,
      questions: collected,
      successCount: realSuccessCount,
      totalCount: realTotalCount,
      // 填充提交所需字段 (reportId/bizCode), 支持提交做题痕迹
      reportId: effectiveReportId,
      bizCode: '204',
      homeworkId: homeworkId,
      platform: '1',
    );
  }

  /// 通用并发执行器 (对齐 Python ThreadPoolExecutor)
  ///
  /// 将 [items] 分批执行, 每批 [maxConcurrent] 个任务并发,
  /// 返回每个任务的执行结果列表 (与输入顺序一致, 过滤 null)。
  Future<List<T>> _runConcurrent<T>(
    List<String> items,
    int maxConcurrent,
    Future<T> Function(String item) task,
  ) async {
    final results = List<T?>.filled(items.length, null);
    for (var i = 0; i < items.length; i += maxConcurrent) {
      if (_cancelled) break;
      final end = (i + maxConcurrent < items.length)
          ? i + maxConcurrent
          : items.length;
      final batch = items.sublist(i, end);
      final futures = <Future<void>>[];
      for (var j = 0; j < batch.length; j++) {
        final idx = i + j;
        final item = batch[j];
        futures.add(() async {
          results[idx] = await task(item);
        }());
      }
      await Future.wait(futures);
    }
    return results.whereType<T>().toList();
  }

  /// 通用并发执行器 (保留 null, 用于追踪失败项)
  ///
  /// 与 [_runConcurrent] 类似, 但返回 [List<T?>] 保留 null,
  /// 调用方可据此统计失败数量。
  /// 支持任意输入类型 [I], 适配非 String 的 items (如 Map)。
  Future<List<T?>> _runConcurrentNullable<I, T>(
    List<I> items,
    int maxConcurrent,
    Future<T?> Function(I item) task,
  ) async {
    final results = List<T?>.filled(items.length, null);
    for (var i = 0; i < items.length; i += maxConcurrent) {
      if (_cancelled) break;
      final end = (i + maxConcurrent < items.length)
          ? i + maxConcurrent
          : items.length;
      final batch = items.sublist(i, end);
      final futures = <Future<void>>[];
      for (var j = 0; j < batch.length; j++) {
        final idx = i + j;
        final item = batch[j];
        futures.add(() async {
          results[idx] = await task(item);
        }());
      }
      await Future.wait(futures);
    }
    return results;
  }

  /// 格式化子题题号为 "父号-子序号" (便于展示定位)
  ///
  /// 对齐原 _fetchViaEscalation 中循环内的子题 number 补全逻辑,
  /// 抽取为公共方法供 reportId / direct 方案复用。
  QuestionInfo _formatChildQuestionNumbers(
    QuestionInfo info,
    String parentNumber,
  ) {
    if (info.childQuestions.isEmpty || parentNumber.isEmpty) return info;
    final updatedChildren = <QuestionInfo>[];
    for (int idx = 0; idx < info.childQuestions.length; idx++) {
      final cq = info.childQuestions[idx];
      updatedChildren.add(
        QuestionInfo(
          number: cq.number.isNotEmpty
              ? '$parentNumber-${cq.number}'
              : '$parentNumber-${idx + 1}',
          group: cq.group,
          answer: cq.answer,
          analysis: cq.analysis,
          knowledge: cq.knowledge,
          questionType: cq.questionType,
          questionContent: cq.questionContent,
          options: cq.options,
          childQuestions: cq.childQuestions,
          difficulty: cq.difficulty,
          id: cq.id,
          cate: cq.cate,
          subjective: cq.subjective,
          questionNoShow: cq.questionNoShow,
          questionSort: cq.questionSort,
          parentId: cq.parentId.isNotEmpty
              ? cq.parentId
              : (info.id.isNotEmpty ? info.id : parentNumber),
          rightAnswerRaw: cq.rightAnswerRaw,
        ),
      );
    }
    return QuestionInfo(
      number: info.number,
      group: info.group,
      answer: info.answer,
      analysis: info.analysis,
      knowledge: info.knowledge,
      questionType: info.questionType,
      questionContent: info.questionContent,
      options: info.options,
      childQuestions: updatedChildren,
      difficulty: info.difficulty,
      id: info.id,
      cate: info.cate,
      subjective: info.subjective,
      questionNoShow: info.questionNoShow,
      questionSort: info.questionSort,
      parentId: info.parentId,
      rightAnswerRaw: info.rightAnswerRaw,
    );
  }

  /// 获取单题答案解析 (reportId 方案并发工作线程调用, 默认 bizCode=201)
  ///
  /// 对齐 debug/GetEWTAnswers/ewt.js getAnswer:
  ///   - 调 getQuestionAnalysis(rid, qid, bizCode, homeworkId='0')
  ///   - 205 回退时 bizCode=205 (对齐 Web mystudy 测一测卷)
  ///   - 直接用响应 data 构造 QuestionInfo, 不依赖 getAnswerPaper 预取
  ///   - 从 answerSheetSubGroup 的 meta 补充 id/subjective/cate (服务端 analysis
  ///     响应不返回这些字段, 但提交做题痕迹时需要)
  ///   - 子题 number 补全为 "父号-子序号"
  ///
  /// [item] 包含 qid/number/group/meta
  /// 返回 null 表示获取失败 (调用方统计 failCount)
  Future<QuestionInfo?> _fetchAndMergeAnalysis(
    Map<String, dynamic> item, {
    required String paperId,
    required String reportId,
    required String homeworkId,
    String bizCode = '201',
  }) async {
    if (_cancelled) return null;
    final qid = item['qid'] as String;
    final parentNumber = item['number'] as String;
    final groupName = item['group'] as String;
    final meta = item['meta'] as Map<String, dynamic>;

    try {
      final analysisResult = await _answerRemote.getQuestionAnalysis(
        paperId: paperId,
        reportId: reportId,
        questionId: qid,
        bizCode: bizCode,
        homeworkId: homeworkId,
      );
      if (analysisResult['success'] != true) {
        _log(
          '  题目 $parentNumber($qid) 答案获取失败: '
          '${analysisResult['message'] ?? '未知错误'}',
          level: LogLevel.warning,
        );
        return null;
      }
      final aData = analysisResult['data'];
      if (aData is! Map<String, dynamic>) return null;

      // 205 链锁定判定: 未完成试卷的报告未解锁, analysis 返回
      // rightAnswer=[]/analyse='' 的空数据, 视为失败 (避免空答案误报成功)。
      // 205 已完成的试卷 (任务列表完成报告) 已解锁, 不受影响。
      if (bizCode == '205') {
        final lockedAnswers = (aData['rightAnswer'] as List<dynamic>?) ?? [];
        final lockedAnalyse = (aData['analyse']?.toString() ?? '')
            .trim()
            .isEmpty;
        if (lockedAnswers.isEmpty && lockedAnalyse) {
          _log(
            '  题目 $parentNumber($qid) 205 报告未解锁 (试卷未交卷), '
            '跳过该题',
            level: LogLevel.warning,
          );
          return null;
        }
      }

      // getQuestionAnalysis 响应不含 id/subjective/cate,
      // 从 answerSheetSubGroup 的 meta 补充, 防止:
      //   - 主观题被当作客观题用 myAnswers 提交 (服务端返回 7771202)
      //   - 题目缺 id 无法识别/提交
      if (!aData.containsKey('id') && !aData.containsKey('questionId')) {
        aData['id'] = qid;
      }
      if (!aData.containsKey('subjective')) {
        aData['subjective'] = meta['subjective'] ?? false;
      }
      if (!aData.containsKey('cate') && !aData.containsKey('cateId')) {
        aData['cate'] = meta['cateId'] ?? 0;
      }

      final info = QuestionInfo.fromJson(
        aData,
        number: parentNumber,
        group: groupName,
      );
      // 子题 number 补全为 "父号-子序号"
      return _formatChildQuestionNumbers(info, parentNumber);
    } catch (e) {
      _log('  题目 $parentNumber($qid) 答案获取异常: $e', level: LogLevel.warning);
      return null;
    }
  }

  /// 获取单题答案解析 (direct 方案并发工作线程调用, bizCode=204)
  ///
  /// 对齐原 _fetchDirect 循环体内的逻辑:
  /// - 分组题 (isParent=true): 用 analysis 响应更新子题答案, 保留父题字段
  /// - 普通题: 合并原始 info 的 id/subjective/cate 后构建 QuestionInfo
  /// - 失败时回退到原始题干 (答案为空), 不丢弃题目 (确保解析准确性)
  ///
  /// 始终返回 QuestionInfo (成功含答案, 失败保留原始题干), 不会返回 null。
  Future<QuestionInfo> _fetchDirectSingleAnalysis(
    Map<String, dynamic> item, {
    required String paperId,
    required String reportId,
    required String homeworkId,
  }) async {
    if (_cancelled) {
      return _fallbackInfo(item);
    }
    final qid = item['qid'] as String;
    try {
      final analysisResult = await _answerRemote.getQuestionAnalysis(
        paperId: paperId,
        reportId: reportId,
        questionId: qid,
        bizCode: '204',
        homeworkId: homeworkId.isNotEmpty ? homeworkId : '0',
      );
      if (analysisResult['success'] != true) {
        _log('  逐题查询失败 qid=$qid, 保留题干', level: LogLevel.warning);
        return _fallbackInfo(item);
      }
      final aData = analysisResult['data'];
      if (aData is! Map<String, dynamic>) {
        return _fallbackInfo(item);
      }

      if (item['isParent'] == true) {
        // 分组题: 用 analysis 更新子题答案
        final parentInfo = item['info'] as QuestionInfo;
        final aChildren = (aData['childQuestions'] as List<dynamic>?) ?? [];
        final updatedChildren = <QuestionInfo>[];
        for (int idx = 0; idx < aChildren.length; idx++) {
          final cq = aChildren[idx];
          if (cq is Map<String, dynamic>) {
            // getQuestionAnalysis 返回的子题不含 id/subjective/cate,
            // 用原始解析的 parentInfo.childQuestions[idx] 补充,
            // 避免子题缺 id 无法识别/提交, 以及主观子题被当作客观题
            // 用 myAnswers 提交 (7771202)
            if (idx < parentInfo.childQuestions.length) {
              final origChild = parentInfo.childQuestions[idx];
              if (!cq.containsKey('id') && !cq.containsKey('questionId')) {
                cq['id'] = origChild.id;
              }
              if (!cq.containsKey('subjective')) {
                cq['subjective'] = origChild.subjective;
              }
              if (!cq.containsKey('cate') && !cq.containsKey('cateId')) {
                cq['cate'] = origChild.cate;
              }
              // 补齐子题题干/选项 (analysis 子题通常不含, 无答案时兜底)
              _fillBlankContent(cq, origChild);
            }
            final childInfo = QuestionInfo.fromJson(
              cq,
              number: idx < parentInfo.childQuestions.length
                  ? parentInfo.childQuestions[idx].number
                  : '${idx + 1}',
            );
            updatedChildren.add(childInfo);
          }
        }
        return QuestionInfo(
          number: parentInfo.number,
          group: parentInfo.group,
          answer: parentInfo.answer,
          analysis: parentInfo.analysis,
          knowledge: parentInfo.knowledge,
          questionType: parentInfo.questionType,
          questionContent: parentInfo.questionContent,
          options: parentInfo.options,
          childQuestions: updatedChildren.isNotEmpty
              ? updatedChildren
              : parentInfo.childQuestions,
          difficulty: parentInfo.difficulty,
          id: parentInfo.id,
          cate: parentInfo.cate,
          subjective: parentInfo.subjective,
          questionNoShow: parentInfo.questionNoShow,
          questionSort: parentInfo.questionSort,
          parentId: parentInfo.parentId,
          rightAnswerRaw: parentInfo.rightAnswerRaw,
        );
      } else {
        // 普通题: 合并原始 info 的 id/subjective/cate
        final origInfo = item['info'] as QuestionInfo;
        if (!aData.containsKey('id') && !aData.containsKey('questionId')) {
          aData['id'] = origInfo.id;
        }
        if (!aData.containsKey('subjective')) {
          aData['subjective'] = origInfo.subjective;
        }
        if (!aData.containsKey('cate') && !aData.containsKey('cateId')) {
          aData['cate'] = origInfo.cate;
        }
        // 补齐题干/选项/题型/难度 (analysis 响应通常不含这些字段,
        // 无答案时用原始题干兜底, 确保题目/选项/题干仍能正确展示)
        _fillBlankContent(aData, origInfo);
        return QuestionInfo.fromJson(
          aData,
          number: item['number'] as String,
          group: item['group'] as String,
        );
      }
    } catch (e) {
      _log('  逐题查询失败 qid=$qid: $e, 保留题干', level: LogLevel.warning);
      return _fallbackInfo(item);
    }
  }

  /// 从 item 中恢复原始题干 (答案为空), 用于补全失败时的兜底
  ///
  /// 对齐原 _fetchDirect 中 _fallbackAddInfo 的行为,
  /// 返回原始 QuestionInfo (答案可能为空), 不丢弃题目。
  QuestionInfo _fallbackInfo(Map<String, dynamic> item) {
    final info = item['info'] as QuestionInfo?;
    if (info != null) return info;
    // info 为 null 时返回空 QuestionInfo (不应发生, 但防御性处理)
    return const QuestionInfo();
  }

  /// 用原始题干信息补齐 analysis 响应缺失的展示字段
  ///
  /// getQuestionAnalysis 的响应通常只含 rightAnswer/analyse/knowledges,
  /// 不含 questionContent/options 等题干字段。直接获取方案下, 当答案为空
  /// (未作答/未解锁) 时, 若用 analysis 数据整体覆盖原始题干, 会导致题目/
  /// 选项/题干全部丢失。此方法仅在 analysis 缺失对应字段时用原始信息兜底,
  /// 确保"直接获取"没有答案时仍能正确展示题目、选项和题干。
  void _fillBlankContent(Map<String, dynamic> data, QuestionInfo orig) {
    if (_isBlank(data['questionContent'])) {
      data['questionContent'] = orig.questionContent;
    }
    if (data['options'] is! List || (data['options'] as List).isEmpty) {
      data['options'] = orig.options;
    }
    if (_isBlank(data['subjectQuestionTypeName']) &&
        _isBlank(data['questionTypeName']) &&
        _isBlank(data['cateName'])) {
      data['subjectQuestionTypeName'] = orig.questionType;
    }
    if (_isBlank(data['degreeRangeDesc'])) {
      data['degreeRangeDesc'] = orig.difficulty;
    }
  }

  bool _isBlank(dynamic v) {
    final s = v?.toString() ?? '';
    return s.trim().isEmpty;
  }

  // ─── paperId 解析辅助 ───

  /// 从 URL 中提取 paperId
  static String extractPaperId(String contentUrl) {
    return _extractUrlParam(contentUrl, 'paperId');
  }

  /// 从 URL 中提取指定查询参数值
  ///
  /// 用于从答题页面 URL (如 answer-pc/exam/answer?bizCode=205&homeworkId=xxx
  /// &paperId=xxx&reportId=xxx) 中解析提交所需的页面参数。
  /// 兼容完整 URL / 相对路径 / 纯查询字符串。
  static String _extractUrlParam(String url, String key) {
    return _parseUrlParams(url)[key] ?? '';
  }

  /// 从 URL 中一次性解析所有查询参数
  ///
  /// 用于需要从同一 URL 提取多个参数 (如 reportId/bizCode/homeworkId) 的场景,
  /// 避免重复调用 [_extractUrlParam] 造成的多次 split + parseQueryString 开销。
  /// 兼容完整 URL / 相对路径 / 纯查询字符串。
  static Map<String, String> _parseUrlParams(String url) {
    if (url.isEmpty) return const {};
    final queryPart = url.contains('?') ? url.split('?').last : url;
    if (queryPart.isEmpty) return const {};
    return Uri.splitQueryString(queryPart);
  }

  /// 通过 studyGuide 接口获取 paperId/reportId
  Future<(String, String)> _fetchFromStudyGuide(
    Map<String, dynamic> course,
    String homeworkId,
    String schoolId,
  ) async {
    final lessonId =
        (course['lessonId'] ?? course['contentId'] ?? course['id'] ?? '')
            .toString();
    if (lessonId.isEmpty || schoolId.isEmpty) return ('', '');

    final taskId = (course['taskId'] ?? course['task_id'] ?? '').toString();
    try {
      final result = await _answerRemote.getStudyGuideAndPractice(
        schoolId: schoolId,
        homeworkId: homeworkId,
        taskIds: taskId.isNotEmpty ? [taskId] : [],
        lessonIds: [lessonId],
      );

      // 响应可能是 {list: [...]} 或直接是 Map
      List<dynamic> data = [];
      if (result.containsKey('list')) {
        data = (result['list'] as List<dynamic>?) ?? [];
      } else if (result.containsKey('data')) {
        data = (result['data'] as List<dynamic>?) ?? [];
      }

      // 查找匹配 lessonId 的项
      Map<String, dynamic>? target;
      for (final item in data) {
        if (item is Map<String, dynamic> &&
            item['lessonId']?.toString() == lessonId) {
          target = item;
          break;
        }
      }
      // 回退: 取第一个有 studyTest 的项
      target ??= data
          .whereType<Map<String, dynamic>>()
          .where((item) => item['studyTest'] != null)
          .firstOrNull;

      if (target == null) return ('', '');

      final studyTest = target['studyTest'];
      if (studyTest is! Map<String, dynamic>) return ('', '');

      var paperId = (studyTest['paperId'] ?? '').toString();
      var reportId = (studyTest['reportId'] ?? '').toString();
      if (paperId == '0') paperId = '';
      if (reportId == '0') reportId = '';

      if (paperId.isNotEmpty) {
        _log('  studyGuide: paperId=$paperId, reportId=$reportId');
      }
      return (paperId, reportId);
    } catch (e) {
      _log('  studyGuide 查询异常: $e', level: LogLevel.warning);
      return ('', '');
    }
  }

  /// 通过 getLessonDetailV2 获取 paperId
  ///
  /// 仅当 studyGuide 失败时调用 (回退方案)。
  /// 参数在 [HomeworkRemoteDataSource.getLessonDetail] 内部转为 int 类型,
  /// 避免含特殊字符 (如 %) 的参数导致 URI 编码异常。
  Future<String> _fetchFromLessonDetail(
    Map<String, dynamic> course,
    String homeworkId,
    String schoolId,
  ) async {
    final lessonId =
        (course['lessonId'] ?? course['contentId'] ?? course['id'] ?? '')
            .toString();
    if (lessonId.isEmpty || homeworkId.isEmpty || schoolId.isEmpty) return '';

    try {
      final detail = await _homeworkRemote.getLessonDetail(
        schoolId: schoolId,
        lessonId: lessonId,
        homeworkId: homeworkId,
      );
      // 递归搜索 paperId
      return _searchPaperId(detail);
    } catch (e) {
      _log('  getLessonDetailV2 异常: $e', level: LogLevel.warning);
      return '';
    }
  }

  /// 递归搜索 Map/List 中的 paperId
  String _searchPaperId(dynamic obj) {
    if (obj is String) {
      final pid = extractPaperId(obj);
      if (pid.isNotEmpty) return pid;
    } else if (obj is Map<String, dynamic>) {
      // 优先搜索特定字段
      for (final field in [
        'paperBindVideo',
        'paperReport',
        'paper',
        'testPaper',
      ]) {
        final val = obj[field];
        if (val is Map<String, dynamic>) {
          final pid = (val['paperId'] ?? '').toString();
          if (pid.isNotEmpty && pid != '0') return pid;
        } else if (val is String) {
          final pid = extractPaperId(val);
          if (pid.isNotEmpty) return pid;
          if (RegExp(r'^\d+$').hasMatch(val) && val != '0') return val;
        }
      }
      // 递归搜索所有值
      for (final v in obj.values) {
        final pid = _searchPaperId(v);
        if (pid.isNotEmpty) return pid;
      }
    } else if (obj is List) {
      for (final item in obj) {
        final pid = _searchPaperId(item);
        if (pid.isNotEmpty) return pid;
      }
    }
    return '';
  }

  int _parseContentType(Map<String, dynamic> course) {
    final ct = course['contentType'] ?? course['content_type'];
    if (ct is int) return ct;
    if (ct is String) return int.tryParse(ct) ?? 1;
    return 1;
  }
}
