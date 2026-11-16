/// 作业页面统一状态管理与 Riverpod Provider：作业列表分页加载、状态/学科/类型筛选及作业-课程双视图切换。
/// 筛选选项常量与 Python STATUS_API_MAP/TYPE_API_MAP 保持一致。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/answer/data/datasources/answer_remote_datasource.dart';
import 'package:ewt_auto_client/features/auth/presentation/providers/auth_provider.dart';

import '../../data/datasources/homework_remote_datasource.dart';

// ─── Constants ───

/// 筛选选项: 状态 (与 Python STATUS_API_MAP 一致)
const List<(int?, String)> statusFilterOptions = [
  (2, '进行中'),
  (1, '未开始'),
  (3, '已截止'),
];

/// 筛选选项: 学科 (对齐 getStudentHomeworkDaySubjectStat 接口, subjectId 1-12)
const List<(int?, String)> subjectFilterOptions = [
  (null, '全部'),
  (1, '语文'),
  (2, '数学'),
  (3, '英语'),
  (4, '物理'),
  (5, '化学'),
  (6, '生物'),
  (7, '政治'),
  (8, '历史'),
  (9, '地理'),
  (10, '心灵成长'),
  (11, '生涯规划'),
  (12, '综合素养'),
];

/// 筛选选项: 类型 (与 Python TYPE_API_MAP 一致)
const List<(int?, String)> typeFilterOptions = [
  (null, '全部试卷测评'),
  (2, '选科视频'),
  (3, '学科专项专题'),
];

/// 每页加载数量
const int kPageSize = 20;

// ─── State ───

/// 作业页面统一状态
class HomeworkState {
  /// 任务列表（作业列表视图）
  final List<Map<String, dynamic>> tasks;

  /// 是否正在加载
  final bool isLoading;

  /// 是否还有更多数据
  final bool hasMore;

  /// 当前页码
  final int currentPage;

  /// 筛选: 状态 (null=全部)
  final int? filterStatus;

  /// 筛选: 学科 (null=全部)
  final int? filterSubject;

  /// 筛选: 类型 (null=全部)
  final int? filterType;

  /// 视图模式: 'tasks' | 'courses'
  final String viewMode;

  /// 当前进入的作业 ID（课程视图）
  final String? currentHomeworkId;

  /// 当前作业标题（课程视图）
  final String? currentHomeworkTitle;

  /// 日期统计列表（课程视图顶部日期按钮, 来自 dateStat）
  final List<Map<String, dynamic>> dateStats;

  /// 学科统计列表（课程视图学科筛选, 来自 subjectStat）
  ///
  /// 动态列表: 由 getStudentHomeworkDaySubjectStat 接口返回,
  /// 含 subjectId/subjectName/taskCount/finishCount 等字段。
  final List<Map<String, dynamic>> subjectStats;

  /// 课程/任务列表（课程视图, 当前日期 + 学科筛选前的原始列表）
  final List<Map<String, dynamic>> courses;

  /// 当前选中的日期 ID (单日期模式, 或多选模式下的代表日期)
  final String? selectedDateId;

  /// 当前选中的多个日期 ID (日期多选模式)
  final Set<String> selectedDateIds;

  /// 是否处于日期多选模式
  final bool dateMultiSelect;

  /// 当前选中的学科 ID (null=全部学科, 来自 subjectStat 的 subjectId)
  final int? selectedSubjectId;

  /// 当前选中的多个学科 ID (学科多选模式)
  final Set<int> selectedSubjectIds;

  /// 是否处于学科多选模式
  final bool subjectMultiSelect;

  /// 筛选模式: 'date' (按日期) | 'subject' (按学科, 显示该学科所有日期课程)
  ///
  /// 二者互斥: date 模式按日期筛选, subject 模式加载所有日期课程后按学科筛选。
  final String filterMode;

  /// 错误信息
  final String? error;

  /// 总数量
  final int totalCount;

  /// 课程视图是否加载中
  final bool isCourseLoading;

  const HomeworkState({
    this.tasks = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.currentPage = 1,
    this.filterStatus = 2,
    this.filterSubject,
    this.filterType,
    this.viewMode = 'tasks',
    this.currentHomeworkId,
    this.currentHomeworkTitle,
    this.dateStats = const [],
    this.subjectStats = const [],
    this.courses = const [],
    this.selectedDateId,
    this.selectedDateIds = const {},
    this.dateMultiSelect = false,
    this.selectedSubjectId,
    this.selectedSubjectIds = const {},
    this.subjectMultiSelect = false,
    this.filterMode = 'date',
    this.error,
    this.totalCount = 0,
    this.isCourseLoading = false,
  });

  /// 当前筛选后的课程列表
  ///
  /// - date 模式: courses 已按日期加载, 直接返回 (不应用学科筛选)
  /// - subject 模式: courses 为所有日期课程, 按学科筛选
  ///   * 学科多选: 命中 selectedSubjectIds 集合中的任一学科
  ///   * 单学科: 命中 selectedSubjectId
  ///   * 未选中: 返回全部
  List<Map<String, dynamic>> get filteredCourses {
    if (filterMode != 'subject') return courses;

    final Set<int>? multiIds = subjectMultiSelect ? selectedSubjectIds : null;
    final int? singleId = multiIds != null ? null : selectedSubjectId;
    if (multiIds == null && singleId == null) return courses;

    bool matchSubject(int? sidInt, String? sname) {
      if (multiIds != null) {
        if (sidInt != null && multiIds.contains(sidInt)) return true;
      } else {
        if (sidInt != null && sidInt == singleId) return true;
      }
      if (sname != null && sname.isNotEmpty) {
        for (final s in subjectStats) {
          final ssid = s['subjectId'];
          final ssidInt = ssid is int ? ssid : int.tryParse(ssid?.toString() ?? '');
          final hit = multiIds != null
              ? (ssidInt != null && multiIds.contains(ssidInt))
              : (ssidInt == singleId);
          if (hit && s['subjectName']?.toString() == sname) return true;
        }
      }
      return false;
    }

    return courses.where((c) {
      final sid = c['subjectId'];
      final sidInt = sid != null ? int.tryParse(sid.toString()) : null;
      final sname = c['subjectName']?.toString();
      return matchSubject(sidInt, sname);
    }).toList();
  }

  HomeworkState copyWith({
    List<Map<String, dynamic>>? tasks,
    bool? isLoading,
    bool? hasMore,
    int? currentPage,
    int? Function()? filterStatus,
    int? Function()? filterSubject,
    int? Function()? filterType,
    String? viewMode,
    String? Function()? currentHomeworkId,
    String? Function()? currentHomeworkTitle,
    List<Map<String, dynamic>>? dateStats,
    List<Map<String, dynamic>>? subjectStats,
    List<Map<String, dynamic>>? courses,
    String? Function()? selectedDateId,
    Set<String>? selectedDateIds,
    bool? dateMultiSelect,
    int? Function()? selectedSubjectId,
    Set<int>? selectedSubjectIds,
    bool? subjectMultiSelect,
    String? filterMode,
    String? Function()? error,
    int? totalCount,
    bool? isCourseLoading,
  }) {
    return HomeworkState(
      tasks: tasks ?? this.tasks,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      currentPage: currentPage ?? this.currentPage,
      filterStatus: filterStatus != null ? filterStatus() : this.filterStatus,
      filterSubject:
          filterSubject != null ? filterSubject() : this.filterSubject,
      filterType: filterType != null ? filterType() : this.filterType,
      viewMode: viewMode ?? this.viewMode,
      currentHomeworkId: currentHomeworkId != null
          ? currentHomeworkId()
          : this.currentHomeworkId,
      currentHomeworkTitle: currentHomeworkTitle != null
          ? currentHomeworkTitle()
          : this.currentHomeworkTitle,
      dateStats: dateStats ?? this.dateStats,
      subjectStats: subjectStats ?? this.subjectStats,
      courses: courses ?? this.courses,
      selectedDateId:
          selectedDateId != null ? selectedDateId() : this.selectedDateId,
      selectedDateIds: selectedDateIds ?? this.selectedDateIds,
      dateMultiSelect: dateMultiSelect ?? this.dateMultiSelect,
      selectedSubjectId: selectedSubjectId != null
          ? selectedSubjectId()
          : this.selectedSubjectId,
      selectedSubjectIds: selectedSubjectIds ?? this.selectedSubjectIds,
      subjectMultiSelect: subjectMultiSelect ?? this.subjectMultiSelect,
      filterMode: filterMode ?? this.filterMode,
      error: error != null ? error() : this.error,
      totalCount: totalCount ?? this.totalCount,
      isCourseLoading: isCourseLoading ?? this.isCourseLoading,
    );
  }
}

// ─── Notifier ───

/// 作业状态管理器
class HomeworkNotifier extends StateNotifier<HomeworkState> {
  final HomeworkRemoteDataSource _remote;
  final AnswerRemoteDataSource _answerRemote;
  final String _schoolId;

  HomeworkNotifier(this._remote, this._answerRemote, this._schoolId)
      : super(const HomeworkState());

  /// 加载任务列表
  ///
  /// [refresh] = true 时重置为第一页
  Future<void> loadTasks({bool refresh = false}) async {
    if (state.isLoading) return;

    final page = refresh ? 1 : state.currentPage;

    state = state.copyWith(
      isLoading: true,
      error: () => null,
      currentPage: page,
    );

    try {
      final list = await _remote.getHomeworkList(
        schoolId: _schoolId,
        subject: state.filterSubject,
        type: state.filterType,
        status: state.filterStatus,
        pageIndex: page,
        pageSize: kPageSize,
      );
      final items = list.whereType<Map<String, dynamic>>().toList();

      final newTasks = refresh ? items : [...state.tasks, ...items];

      state = state.copyWith(
        tasks: newTasks,
        isLoading: false,
        hasMore: items.length >= kPageSize,
        currentPage: page + 1,
        totalCount: newTasks.length,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: () => '加载失败: $e',
      );
    }
  }

  /// 加载更多（无限滚动）
  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoading) return;
    await loadTasks(refresh: false);
  }

  /// 设置筛选条件并重新加载
  Future<void> setFilter({
    int? Function()? status,
    int? Function()? subject,
    int? Function()? type,
  }) async {
    state = state.copyWith(
      filterStatus: status,
      filterSubject: subject,
      filterType: type,
      tasks: [],
      currentPage: 1,
      hasMore: true,
    );
    await loadTasks(refresh: true);
  }

  /// 进入课程视图（钻取某个作业）
  Future<void> enterCourseView(String homeworkId, {String? title}) async {
    state = state.copyWith(
      viewMode: 'courses',
      currentHomeworkId: () => homeworkId,
      currentHomeworkTitle: () => title,
      isCourseLoading: true,
      dateStats: [],
      subjectStats: [],
      courses: [],
      selectedDateId: () => null,
      selectedDateIds: const {},
      dateMultiSelect: false,
      selectedSubjectId: () => null,
      selectedSubjectIds: const {},
      subjectMultiSelect: false,
      filterMode: 'date',
      error: () => null,
    );

    try {
      // 获取日期 + 学科统计 (返回 {subjectStat, dateStat})
      final statsMap = await _remote.getDaySubjectStat(
        homeworkId: homeworkId,
        schoolId: _schoolId,
      );
      final dateList = (statsMap['dateStat'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final subjectList = (statsMap['subjectStat'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      // 默认选中第一个日期
      final firstDateId = dateList.isNotEmpty
          ? (dateList.first['dateId']?.toString() ??
              dateList.first['dayId']?.toString() ??
              dateList.first['id']?.toString())
          : null;

      state = state.copyWith(
        dateStats: dateList,
        subjectStats: subjectList,
        selectedDateId: () => firstDateId,
      );

      // 加载该日期下的课程
      if (firstDateId != null) {
        await _loadCourses(homeworkId, firstDateId);
      } else {
        state = state.copyWith(isCourseLoading: false);
      }
    } catch (e) {
      state = state.copyWith(
        isCourseLoading: false,
        error: () => '加载课程失败: $e',
      );
    }
  }

  /// 选择日期（课程视图）
  ///
  /// 切换日期时保留当前学科筛选, 重新加载该日期下所有课程,
  /// 学科筛选通过 [filteredCourses] getter 在 UI 层应用。
  /// 单日期选择会退出多选模式 (selectedDateIds 同步为单元素集合)。
  Future<void> selectDate(String dateId) async {
    final homeworkId = state.currentHomeworkId;
    if (homeworkId == null) return;

    state = state.copyWith(
      selectedDateId: () => dateId,
      selectedDateIds: {dateId},
      dateMultiSelect: false,
      isCourseLoading: true,
      courses: [],
    );

    await _loadCourses(homeworkId, dateId);
  }

  /// 应用日期多选 (来自多选弹窗的确认)
  ///
  /// 设置 [selectedDateIds] 并进入多选模式, 加载所有选中日期的课程 (并集)。
  /// [dateIds] 为空时退化为单日期模式 (无选中)。
  Future<void> applyMultiDateSelection(List<String> dateIds) async {
    final homeworkId = state.currentHomeworkId;
    if (homeworkId == null) return;

    final ids = dateIds.toSet();
    state = state.copyWith(
      selectedDateId: () => ids.isNotEmpty ? ids.first : null,
      selectedDateIds: ids,
      dateMultiSelect: true,
      isCourseLoading: true,
      courses: [],
      error: () => null,
    );

    await _loadCoursesForDates(ids.toList());
  }

  /// 退出日期多选模式 (回到单日期模式, 重新加载首个日期)
  Future<void> exitDateMultiSelect() async {
    final homeworkId = state.currentHomeworkId;
    if (homeworkId == null) return;
    final firstDateId = state.dateStats.isNotEmpty
        ? (state.dateStats.first['dateId']?.toString() ??
            state.dateStats.first['dayId']?.toString() ??
            state.dateStats.first['id']?.toString())
        : null;
    state = state.copyWith(
      dateMultiSelect: false,
      selectedDateIds: const {},
    );
    if (firstDateId != null) {
      await selectDate(firstDateId);
    }
  }

  /// 加载多个日期下的课程并合并 (日期多选模式)
  ///
  /// 依次拉取每个选中日期的课程, 注入 dayId/dateLabel, 统一合并导学案/练习
  /// 完成状态, 最终结果 [courses] 为各日期课程的并集。
  Future<void> _loadCoursesForDates(List<String> dateIds) async {
    final homeworkId = state.currentHomeworkId;
    if (homeworkId == null) return;
    if (dateIds.isEmpty) {
      state = state.copyWith(isCourseLoading: false, courses: const []);
      return;
    }
    try {
      final all = <Map<String, dynamic>>[];
      for (final dateId in dateIds) {
        final result = await _remote.getHomeworkTasks(
          homeworkId: homeworkId,
          schoolId: _schoolId,
          dayId: dateId,
          pageIndex: 1,
          pageSize: 200,
        );
        final list = result['data'] as List<dynamic>? ?? [];
        final dateLabel = _dateLabelForDayId(dateId);
        for (final c in list.whereType<Map<String, dynamic>>()) {
          c['dayId'] = dateId;
          if (dateLabel != null) c['dateLabel'] = dateLabel;
          all.add(c);
        }
      }
      final merged = await _mergeStudyGuideStatus(homeworkId, all);
      if (!mounted) return;
      state = state.copyWith(
        courses: merged,
        isCourseLoading: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isCourseLoading: false,
        error: () => '加载课程任务失败: $e',
      );
    }
  }

  /// 选择学科（课程视图学科筛选）
  ///
  /// [subjectId] 为 null 表示全部学科。学科筛选为客户端过滤,
  /// 不重新请求接口, 直接通过 [HomeworkState.filteredCourses] 应用。
  /// 单学科选择会退出多选模式 (selectedSubjectIds 同步清空)。
  void selectSubject(int? subjectId) {
    state = state.copyWith(
      selectedSubjectId: () => subjectId,
      subjectMultiSelect: false,
      selectedSubjectIds: const {},
    );
  }

  /// 应用学科多选 (来自多选弹窗的确认)
  ///
  /// 设置 [selectedSubjectIds] 并进入多选模式, 学科筛选在客户端通过
  /// [HomeworkState.filteredCourses] 应用 (courses 已含所有日期的所有学科课程)。
  /// [subjectIds] 为空时退化为单学科模式 (无选中 → 显示全部)。
  void applyMultiSubjectSelection(List<int> subjectIds) {
    final ids = subjectIds.toSet();
    state = state.copyWith(
      selectedSubjectIds: ids,
      subjectMultiSelect: true,
      selectedSubjectId: () => ids.isNotEmpty ? ids.first : null,
    );
  }

  /// 退出学科多选模式 (回到单学科模式, 选中首个学科)
  void exitSubjectMultiSelect() {
    final firstSid = state.subjectStats.isNotEmpty
        ? (state.subjectStats.first['subjectId'] is int
            ? state.subjectStats.first['subjectId'] as int
            : int.tryParse(
                state.subjectStats.first['subjectId']?.toString() ?? ''))
        : null;
    state = state.copyWith(
      subjectMultiSelect: false,
      selectedSubjectIds: const {},
      selectedSubjectId: () => firstSid,
    );
  }

  /// 切换筛选模式 (日期 / 学科, 二者互斥)
  ///
  /// - 'date': 按日期筛选, 重新加载当前选中日期的课程
  /// - 'subject': 按学科筛选, 加载该作业所有日期的课程, 再按学科过滤
  Future<void> setFilterMode(String mode) async {
    if (mode == state.filterMode) return;
    final homeworkId = state.currentHomeworkId;
    if (homeworkId == null) return;

    state = state.copyWith(
      filterMode: mode,
      isCourseLoading: true,
      courses: [],
      // 切换模式时重置另一维度的筛选
      selectedSubjectId: mode == 'date' ? () => null : null,
      selectedSubjectIds: const {},
      subjectMultiSelect: false,
      selectedDateId: mode == 'subject' ? () => null : null,
      selectedDateIds: const {},
      dateMultiSelect: false,
      error: () => null,
    );

    if (mode == 'subject') {
      // 学科模式: 自动选中第一个学科 (subjectStats 已在作业切换时加载),
      // 避免 selectedSubjectId=null 时所有学科 chip 都未选中 (显示全部课程但无高亮)。
      // subjectStats 为空时保持 null (UI 显示空态)。
      final firstSid = state.subjectStats.isNotEmpty
          ? state.subjectStats.first['subjectId']
          : null;
      final firstSidInt = firstSid is int
          ? firstSid
          : int.tryParse(firstSid?.toString() ?? '');
      if (firstSidInt != null) {
        state = state.copyWith(selectedSubjectId: () => firstSidInt);
      }
      // 加载所有日期的课程并合并作业状态
      await _loadAllCoursesForSubject(homeworkId);
    } else {
      // 日期模式: 重新加载第一个日期的课程
      final firstDateId = state.dateStats.isNotEmpty
          ? (state.dateStats.first['dateId']?.toString() ??
              state.dateStats.first['dayId']?.toString() ??
              state.dateStats.first['id']?.toString())
          : null;
      state = state.copyWith(selectedDateId: () => firstDateId);
      if (firstDateId != null) {
        await _loadCourses(homeworkId, firstDateId);
      } else {
        state = state.copyWith(isCourseLoading: false);
      }
    }
  }

  /// 加载该作业所有日期的课程 (学科模式)
  ///
  /// 合并作业完成状态 (studyGuide), 供学科筛选展示。
  Future<void> _loadAllCoursesForSubject(String homeworkId) async {
    try {
      final allCourses = await fetchAllCourses(homeworkId);
      final merged = await _mergeStudyGuideStatus(homeworkId, allCourses);
      state = state.copyWith(
        courses: merged,
        isCourseLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isCourseLoading: false,
        error: () => '加载全部课程失败: $e',
      );
    }
  }

  /// 根据 dayId 从 [state.dateStats] 查找日期标签 (如 "3月15日")
  ///
  /// dateStat 项含 month/day 字段, dayId/dateId 是 ID 而非日期字符串。
  /// AnswerService 的 {课程日期} 占位符应使用此标签, 而非 dayId。
  String? _dateLabelForDayId(String dayId) {
    for (final day in state.dateStats) {
      final id = day['dateId']?.toString() ??
          day['dayId']?.toString() ??
          day['id']?.toString() ??
          '';
      if (id == dayId) {
        final month = day['month']?.toString() ?? '';
        final dayNum = day['day']?.toString() ?? '';
        if (month.isNotEmpty && dayNum.isNotEmpty) {
          return '$month月$dayNum日';
        }
        return null;
      }
    }
    return null;
  }

  /// 内部: 加载课程列表
  ///
  /// 加载流程:
  /// 1. 调用 pageHomeworkTasks 获取课程列表
  /// 2. 批量调用 queryStudentLessonStudyGuideAndPractice 获取导学案/练习完成状态,
  ///    将 studyTest.finishStatus / practiceSheet.finishStatus 合并到各课程项的
  ///    homeworkFinishStatus 字段 (供 _CourseCard 判定作业完成状态)
  Future<void> _loadCourses(String homeworkId, String dayId) async {
    try {
      final result = await _remote.getHomeworkTasks(
        homeworkId: homeworkId,
        schoolId: _schoolId,
        dayId: dayId,
        pageIndex: 1,
        pageSize: 50,
      );

      final list = result['data'] as List<dynamic>? ?? [];
      var courses = list.whereType<Map<String, dynamic>>().toList();

      // 注入 dayId 和 dateLabel 到各课程项 (dayId 来自 dateStat, 课程对象本身不含此字段)
      // dateLabel 为日期筛选栏的日期 (如 "3月15日"), 供 AnswerService {课程日期} 占位符使用;
      // dayId 是 ID 而非日期字符串, 不应作为 {课程日期} 的值
      final dateLabel = _dateLabelForDayId(dayId);
      for (final c in courses) {
        c['dayId'] = dayId;
        if (dateLabel != null) c['dateLabel'] = dateLabel;
      }

      // 批量获取导学案与练习完成状态, 合并到课程数据
      courses = await _mergeStudyGuideStatus(homeworkId, courses);

      state = state.copyWith(
        courses: courses,
        isCourseLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isCourseLoading: false,
        error: () => '加载课程任务失败: $e',
      );
    }
  }

  /// 批量获取导学案/练习完成状态并合并到课程列表
  ///
  /// 调用 queryStudentLessonStudyGuideAndPractice (支持 lessonIdList + taskIds
  /// 数组批量请求), 按 lessonId 匹配后将 studyTest.finishStatus /
  /// practiceSheet.finishStatus 合并到对应课程项的 homeworkFinishStatus 字段。
  ///
  /// 对于无法通过 studyGuide 接口匹配的课程 (如试卷, contentId 是 paperId 而非
  /// lessonId), 回退使用 pageHomeworkTasks 返回的 `finished` 字段判断完成状态。
  ///
  /// 失败时返回原始 courses 不阻断流程。
  Future<List<Map<String, dynamic>>> _mergeStudyGuideStatus(
    String homeworkId,
    List<Map<String, dynamic>> courses,
  ) async {
    if (courses.isEmpty) return courses;

    // 收集所有 lessonId 和 taskId
    // 注意: 试卷课程的 contentId 是 paperId 而非 lessonId,
    // 传入 studyGuide 接口不会返回匹配结果, 后续靠 finished 字段回退
    final lessonIds = <String>[];
    final taskIds = <String>[];
    for (final c in courses) {
      final lid = (c['lessonId'] ?? c['contentId'] ?? '').toString();
      if (lid.isNotEmpty) lessonIds.add(lid);
      final tid = (c['taskId'] ?? '').toString();
      if (tid.isNotEmpty) taskIds.add(tid);
    }
    if (lessonIds.isEmpty) return courses;

    try {
      final sgResult = await _answerRemote.getStudyGuideAndPractice(
        schoolId: _schoolId,
        homeworkId: homeworkId,
        taskIds: taskIds,
        lessonIds: lessonIds,
      );
      // 响应为列表, 按 lessonId 建立索引
      final sgList = (sgResult['list'] as List<dynamic>?) ?? [];
      final sgMap = <String, Map<String, dynamic>>{};
      for (final item in sgList) {
        if (item is Map<String, dynamic>) {
          final lid = item['lessonId']?.toString();
          if (lid != null && lid.isNotEmpty) sgMap[lid] = item;
        }
      }

      // 合并完成状态到各课程项
      return courses.map((c) {
        final lid = (c['lessonId'] ?? c['contentId'] ?? '').toString();
        final sg = sgMap[lid];

        if (sg != null) {
          // studyTest.finishStatus / practiceSheet.finishStatus: 1=已完成
          final studyTest = sg['studyTest'];
          final practiceSheet = sg['practiceSheet'];
          bool paperDone = false;
          if (studyTest is Map<String, dynamic> &&
              (studyTest['finishStatus'] == 1 ||
                  studyTest['finishStatus'] == true)) {
            paperDone = true;
          }
          if (practiceSheet is Map<String, dynamic> &&
              (practiceSheet['finishStatus'] == 1 ||
                  practiceSheet['finishStatus'] == true)) {
            paperDone = true;
          }

          // 用新接口数据更新作业完成状态:
          // homeworkFinishStatus 供 _CourseCard / CourseDetailDialog 统一判定
          return {
            ...c,
            'homeworkFinishStatus': paperDone ? 1 : 0,
          };
        }

        // studyGuide 接口未返回匹配项 (如试卷课程 contentId=paperId 而非 lessonId):
        // 回退使用 pageHomeworkTasks 返回的 `finished` 字段判断完成状态。
        // `finished` 字段由服务端综合判定, 对试卷和视频课程均准确。
        final finished = c['finished'];
        final isDone = finished == true || finished == 1;
        return {
          ...c,
          'homeworkFinishStatus': isDone ? 1 : 0,
        };
      }).toList();
    } catch (_) {
      // 失败时返回原始数据, 不阻断课程列表展示
      return courses;
    }
  }

  /// 拉取学科列表 (动态列表, 来自 getStudentHomeworkDaySubjectStat)
  ///
  /// 用于配置弹窗的学科筛选 chips: 优先动态加载, 失败返回空列表,
  /// 调用方回退到本地列表 [kCourseSubjects] / [_localSubjects]。
  ///
  /// 返回的学科名称按 subjectId 顺序排列, 与接口 subjectStat 一致。
  Future<List<String>> fetchSubjectList(String homeworkId) async {
    try {
      final statsMap = await _remote.getDaySubjectStat(
        homeworkId: homeworkId,
        schoolId: _schoolId,
      );
      final subjectStat = (statsMap['subjectStat'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final subjects = subjectStat
          .map((s) => s['subjectName']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
      return subjects;
    } catch (_) {
      return [];
    }
  }

  /// 返回任务列表视图
  void backToTasks() {
    state = state.copyWith(
      viewMode: 'tasks',
      currentHomeworkId: () => null,
      currentHomeworkTitle: () => null,
      dateStats: [],
      subjectStats: [],
      courses: [],
      selectedDateId: () => null,
      selectedDateIds: const {},
      dateMultiSelect: false,
      selectedSubjectId: () => null,
      selectedSubjectIds: const {},
      subjectMultiSelect: false,
      filterMode: 'date',
    );
  }

  /// 临时设置 currentHomeworkId (不切换 viewMode, 不清空课程列表)
  ///
  /// 用于任务卡片/日期 chip 右键批量操作: 拉取课程列表后,
  /// 在调用下游 _startProgressReport 等方法前临时设置 homeworkId,
  /// 以便这些方法内部读取 ref.read(homeworkProvider).currentHomeworkId。
  void setCurrentHomeworkId(String homeworkId) {
    state = state.copyWith(
      currentHomeworkId: () => homeworkId,
    );
  }

  /// 拉取一个作业下所有日期的所有课程 (不修改 state)
  ///
  /// 用于任务卡片右键批量操作: 先拉取该作业下所有日期的课程列表,
  /// 再执行进度上报 / 试题答案 / 下载等批量操作。
  ///
  /// 对应 Python: 任务级右键菜单 → 加载该作业下所有课程 → 执行批量操作
  Future<List<Map<String, dynamic>>> fetchAllCourses(
      String homeworkId) async {
    try {
      final statsMap = await _remote.getDaySubjectStat(
        homeworkId: homeworkId,
        schoolId: _schoolId,
      );
      final dateList = (statsMap['dateStat'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      final allCourses = <Map<String, dynamic>>[];
      for (final day in dateList) {
        final dayId = day['dateId']?.toString() ??
            day['dayId']?.toString() ??
            day['id']?.toString() ??
            '';
        if (dayId.isEmpty) continue;
        final result = await _remote.getHomeworkTasks(
          homeworkId: homeworkId,
          schoolId: _schoolId,
          dayId: dayId,
          pageIndex: 1,
          pageSize: 200,
        );
        final list = result['data'] as List<dynamic>? ?? [];
        // 注入 dayId 和 dateLabel 到各课程项
        // dateLabel 为日期筛选栏的日期 (如 "3月15日"), 供 AnswerService {课程日期} 占位符使用
        final month = day['month']?.toString() ?? '';
        final dayNum = day['day']?.toString() ?? '';
        final dateLabel = (month.isNotEmpty && dayNum.isNotEmpty)
            ? '$month月$dayNum日'
            : null;
        for (final c in list.whereType<Map<String, dynamic>>()) {
          c['dayId'] = dayId;
          if (dateLabel != null) c['dateLabel'] = dateLabel;
          allCourses.add(c);
        }
      }
      return allCourses;
    } catch (_) {
      return [];
    }
  }

  /// 拉取特定日期下所有课程 (不修改 state)
  ///
  /// 用于日期 chip 右键批量操作: 先拉取该日期下的所有课程,
  /// 再执行进度上报 / 试题答案 / 下载等批量操作。
  Future<List<Map<String, dynamic>>> fetchCoursesForDate(
      String homeworkId, String dateId) async {
    try {
      final result = await _remote.getHomeworkTasks(
        homeworkId: homeworkId,
        schoolId: _schoolId,
        dayId: dateId,
        pageIndex: 1,
        pageSize: 200,
      );
      final list = result['data'] as List<dynamic>? ?? [];
      // 注入 dayId 和 dateLabel 到各课程项
      // dateLabel 为日期筛选栏的日期 (如 "3月15日"), 供 AnswerService {课程日期} 占位符使用
      final courses = list.whereType<Map<String, dynamic>>().toList();
      final dateLabel = _dateLabelForDayId(dateId);
      for (final c in courses) {
        c['dayId'] = dateId;
        if (dateLabel != null) c['dateLabel'] = dateLabel;
      }
      return courses;
    } catch (_) {
      return [];
    }
  }

  /// 更新任务状态
  Future<bool> updateMissionStatus({
    required String homeworkId,
    required String missionId,
    required int status,
  }) async {
    try {
      await _remote.updateMission(
        homeworkId: homeworkId,
        missionId: missionId,
        status: status,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ─── Provider ───

final homeworkProvider =
    StateNotifierProvider<HomeworkNotifier, HomeworkState>((ref) {
  final client = getIt<DioClient>();
  final remote = HomeworkRemoteDataSource(client);
  final answerRemote = AnswerRemoteDataSource(client);

  // 从认证状态获取 schoolId
  final authState = ref.watch(authProvider);
  final schoolId = authState is AuthAuthenticated
      ? authState.session.schoolId
      : '';

  return HomeworkNotifier(remote, answerRemote, schoolId);
});
