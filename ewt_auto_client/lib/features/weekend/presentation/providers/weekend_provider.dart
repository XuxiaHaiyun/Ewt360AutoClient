/// 周培优 Riverpod 状态管理：WeekendState 持有权限/班级/教材/章节/任务数据，
/// WeekendNotifier 负责加载班级教材列表、切换章节与任务视图。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../settings/presentation/providers/settings_provider.dart';
import '../../data/datasources/weekend_remote_datasource.dart';

/// 周培优页面状态
class WeekendState {
  final bool? hasAuth; // null=未检查, true=有权限, false=无权限
  final List<dynamic> classList;
  final String? selectedClassId;
  final String? selectedClassName;
  final List<dynamic> bookList; // 每项含 chapterList
  final int activeBookIndex;
  final List<dynamic> tasks;
  final String viewMode; // 'chapters' | 'tasks'
  final String? currentChapterName;
  final String? currentChapterId;
  final bool isLoading;
  final String? error;

  const WeekendState({
    this.hasAuth,
    this.classList = const [],
    this.selectedClassId,
    this.selectedClassName,
    this.bookList = const [],
    this.activeBookIndex = 0,
    this.tasks = const [],
    this.viewMode = 'chapters',
    this.currentChapterName,
    this.currentChapterId,
    this.isLoading = false,
    this.error,
  });

  /// 当前选中教材的章节列表（从 bookList 内嵌提取）
  List<dynamic> get currentChapters {
    if (bookList.isEmpty || activeBookIndex >= bookList.length) return [];
    final book = bookList[activeBookIndex];
    if (book is Map<String, dynamic>) {
      return (book['chapterList'] as List<dynamic>?) ?? [];
    }
    return [];
  }

  WeekendState copyWith({
    bool? Function()? hasAuth,
    List<dynamic>? classList,
    String? selectedClassId,
    String? selectedClassName,
    List<dynamic>? bookList,
    int? activeBookIndex,
    List<dynamic>? tasks,
    String? viewMode,
    String? currentChapterName,
    String? currentChapterId,
    bool? isLoading,
    String? error,
  }) {
    return WeekendState(
      hasAuth: hasAuth != null ? hasAuth() : this.hasAuth,
      classList: classList ?? this.classList,
      selectedClassId: selectedClassId ?? this.selectedClassId,
      selectedClassName: selectedClassName ?? this.selectedClassName,
      bookList: bookList ?? this.bookList,
      activeBookIndex: activeBookIndex ?? this.activeBookIndex,
      tasks: tasks ?? this.tasks,
      viewMode: viewMode ?? this.viewMode,
      currentChapterName: currentChapterName ?? this.currentChapterName,
      currentChapterId: currentChapterId ?? this.currentChapterId,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// 周培优 Notifier
///
/// 对应 Python: gui/interfaces/weekly.py
class WeekendNotifier extends StateNotifier<WeekendState> {
  final WeekendRemoteDataSource _remote;
  final String _userId;
  /// 周培优班级越权开关动态读取 (设置页切换后无需重启, 刷新页面即生效)
  final bool Function() _classBypassEnabled;

  WeekendNotifier(
    this._remote,
    this._userId, {
    required bool Function() classBypassEnabled,
  })  : _classBypassEnabled = classBypassEnabled,
        super(const WeekendState());

  /// 加载用户信息（先检查权限，再获取班级列表）
  Future<void> loadUserInfo() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      // 1. 检查周培优权限
      final authResult = await _remote.checkUserAuth(userId: _userId);
      final ispass = authResult['ispass'] == true;

      if (!ispass) {
        state = state.copyWith(
          hasAuth: () => false,
          isLoading: false,
          error: '当前账号无周培优权限',
        );
        return;
      }

      state = state.copyWith(hasAuth: () => true);

      // 2. 获取班级列表
      final userInfo = await _remote.getUserInfo();

      // 防御性提取 classList（兼容多种响应格式）
      List<dynamic> classList = [];
      for (final key in ['classList', 'classes', 'list']) {
        final v = userInfo[key];
        if (v is List && v.isNotEmpty) {
          classList = v;
          break;
        }
      }

      // 班级越权: 合并学校全部周培优班级 (monthly/todo 空 classId)
      // 拉取失败不阻塞正常流程, 仍使用原班级列表
      if (_classBypassEnabled()) {
        try {
          final allClasses = await _remote.getMonthlyTodoClasses();
          if (allClasses.isNotEmpty) {
            classList = _mergeClassLists(classList, allClasses);
          }
        } catch (_) {
          // 忽略越权拉取失败
        }
      }

      if (classList.isEmpty) {
        state = state.copyWith(
          classList: [],
          isLoading: false,
          error: '暂无班级信息',
        );
        return;
      }

      final firstClass = classList.first as Map<String, dynamic>;
      final classId = firstClass['classId']?.toString() ??
          firstClass['id']?.toString() ??
          '';
      final className = firstClass['className']?.toString() ??
          firstClass['name']?.toString() ??
          '';

      state = state.copyWith(
        classList: classList,
        selectedClassId: classId,
        selectedClassName: className,
        isLoading: false,
      );

      // 自动加载教材列表（含章节）
      await _loadBookList();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  /// 选择班级
  Future<void> selectClass(String classId, String className) async {
    if (classId == state.selectedClassId) return;

    state = state.copyWith(
      selectedClassId: classId,
      selectedClassName: className,
      bookList: [],
      activeBookIndex: 0,
      tasks: [],
      viewMode: 'chapters',
      currentChapterName: null,
      currentChapterId: null,
      isLoading: true,
      error: null,
    );

    await _loadBookList();
  }

  /// 选择教材（切换 tab）
  void selectBook(int index) {
    if (index == state.activeBookIndex) return;
    if (index < 0 || index >= state.bookList.length) return;

    state = state.copyWith(
      activeBookIndex: index,
      tasks: [],
      viewMode: 'chapters',
      currentChapterName: null,
      currentChapterId: null,
    );
  }

  /// 进入章节（查看任务列表）
  Future<void> enterChapter(Map<String, dynamic> chapter) async {
    final chapterName = chapter['chapterName']?.toString() ??
        chapter['name']?.toString() ??
        '未知章节';
    final chapterId =
        chapter['chapterId']?.toString() ?? chapter['id']?.toString() ?? '';

    state = state.copyWith(
      viewMode: 'tasks',
      currentChapterName: chapterName,
      currentChapterId: chapterId,
      tasks: [],
      isLoading: true,
      error: null,
    );

    if (chapterId.isEmpty) {
      state = state.copyWith(isLoading: false, error: '章节ID无效');
      return;
    }

    try {
      final classId = state.selectedClassId ?? '';
      final detail = await _remote.getCourseDetail(
        chapterId: chapterId,
        classId: classId,
      );

      // 将 courseDetail 响应展平为任务列表
      final tasks = <Map<String, dynamic>>[];

      // 主课 (单个 dict)
      final mainCourse = detail['mainCourse'];
      if (mainCourse is Map<String, dynamic> &&
          (mainCourse['taskTitle']?.toString() ?? '').isNotEmpty) {
        tasks.add(_convertTask(mainCourse));
      }

      // 周练 (单个 dict)
      final paperPractice = detail['paperPractice'];
      if (paperPractice is Map<String, dynamic> &&
          (paperPractice['taskTitle']?.toString() ?? '').isNotEmpty) {
        tasks.add(_convertTask(paperPractice));
      }

      // 额外练习 (list)
      final extraPractice = detail['extraPractice'];
      if (extraPractice is List) {
        for (final item in extraPractice) {
          if (item is Map<String, dynamic> &&
              (item['taskTitle']?.toString() ?? '').isNotEmpty) {
            tasks.add(_convertTask(item));
          }
        }
      }

      // 评估练习 (单个 dict)
      final evaluatePractice = detail['evaluatePractice'];
      if (evaluatePractice is Map<String, dynamic> &&
          (evaluatePractice['taskTitle']?.toString() ?? '').isNotEmpty) {
        tasks.add(_convertTask(evaluatePractice));
      }

      state = state.copyWith(tasks: tasks, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  /// 拉取指定章节的任务列表 (不切换视图状态, 供批量操作使用)
  ///
  /// 复用 enterChapter 的取数逻辑, 但不修改 state, 仅返回任务列表。
  Future<List<Map<String, dynamic>>> fetchTasksForChapter(
      Map<String, dynamic> chapter) async {
    final chapterId =
        chapter['chapterId']?.toString() ?? chapter['id']?.toString() ?? '';
    if (chapterId.isEmpty) return const [];

    try {
      final classId = state.selectedClassId ?? '';
      final detail = await _remote.getCourseDetail(
        chapterId: chapterId,
        classId: classId,
      );

      final tasks = <Map<String, dynamic>>[];
      final mainCourse = detail['mainCourse'];
      if (mainCourse is Map<String, dynamic> &&
          (mainCourse['taskTitle']?.toString() ?? '').isNotEmpty) {
        tasks.add(_convertTask(mainCourse));
      }
      final paperPractice = detail['paperPractice'];
      if (paperPractice is Map<String, dynamic> &&
          (paperPractice['taskTitle']?.toString() ?? '').isNotEmpty) {
        tasks.add(_convertTask(paperPractice));
      }
      final extraPractice = detail['extraPractice'];
      if (extraPractice is List) {
        for (final item in extraPractice) {
          if (item is Map<String, dynamic> &&
              (item['taskTitle']?.toString() ?? '').isNotEmpty) {
            tasks.add(_convertTask(item));
          }
        }
      }
      final evaluatePractice = detail['evaluatePractice'];
      if (evaluatePractice is Map<String, dynamic> &&
          (evaluatePractice['taskTitle']?.toString() ?? '').isNotEmpty) {
        tasks.add(_convertTask(evaluatePractice));
      }
      return tasks;
    } catch (_) {
      return const [];
    }
  }

  /// 转换周培优任务 contentType 映射
  ///
  /// Python: 4(主课/微专题)→1(视频), 10(周练)→2(试卷)
  Map<String, dynamic> _convertTask(Map<String, dynamic> raw) {
    final task = Map<String, dynamic>.from(raw);
    final contentType = raw['contentType'];
    if (contentType == 4) {
      task['contentType'] = 1;
      task['contentTypeName'] = raw['contentTypeName'] ?? '主课';
    } else if (contentType == 10) {
      task['contentType'] = 2;
      task['contentTypeName'] = raw['contentTypeName'] ?? '周练';
    }
    return task;
  }

  /// 返回章节列表
  void backToChapters() {
    state = state.copyWith(
      viewMode: 'chapters',
      currentChapterName: null,
      currentChapterId: null,
      tasks: [],
    );
  }

  /// 刷新全部数据
  Future<void> refresh() async {
    state = const WeekendState();
    await loadUserInfo();
  }

  /// 内部：加载教材列表（响应已内嵌 chapterList）
  Future<void> _loadBookList() async {
    final classId = state.selectedClassId;
    if (classId == null || classId.isEmpty) return;

    state = state.copyWith(isLoading: true, error: null);
    try {
      final bookList = await _remote.getClassBookList(classId: classId);
      state = state.copyWith(
        bookList: bookList,
        activeBookIndex: 0,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  /// 合并班级列表（按 classId 去重, 保持原列表顺序, 追加越权接口返回的新班级）
  ///
  /// [base] 为用户信息接口返回的班级列表, [extra] 为 monthly/todo 返回的全校班级。
  /// 原班级元素原样保留 (字段更全), 新班级规范化为 {classId, className}。
  List<dynamic> _mergeClassLists(
    List<dynamic> base,
    List<Map<String, dynamic>> extra,
  ) {
    String idOf(Map<String, dynamic> m) =>
        m['classId']?.toString() ?? m['id']?.toString() ?? '';

    final seen = <String>{};
    final merged = <dynamic>[];
    for (final c in base) {
      if (c is Map<String, dynamic>) {
        final id = idOf(c);
        if (id.isNotEmpty) seen.add(id);
      }
      merged.add(c);
    }
    for (final c in extra) {
      final id = idOf(c);
      if (id.isEmpty || !seen.add(id)) continue;
      merged.add({
        'classId': c['classId'] ?? c['id'],
        'className': c['className'] ?? c['name'] ?? '未知班级',
      });
    }
    return merged;
  }
}

/// 周培优 Provider
final weekendProvider =
    StateNotifierProvider<WeekendNotifier, WeekendState>((ref) {
  final client = getIt<DioClient>();
  final authState = ref.watch(authProvider);
  final userId = authState is AuthAuthenticated
      ? authState.session.userId
      : '';
  return WeekendNotifier(
    WeekendRemoteDataSource(client),
    userId,
    classBypassEnabled: () => ref.read(appSettingsProvider).weekendClassBypass,
  );
});