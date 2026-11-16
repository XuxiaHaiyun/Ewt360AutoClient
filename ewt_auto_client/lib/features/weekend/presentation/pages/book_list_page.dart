/// 周培优教材库页面：按学科/层次/阶段/出版社/版本筛选教材列表（服务端仅按
/// 学科过滤，其余由 bookName 客户端解析过滤），支持多选与下载学生版/教师版。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/widgets/context_menu_region.dart';
import '../../../../shared/utils/app_feedback.dart';
import '../../../download/presentation/services/download_service.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../data/datasources/weekend_remote_datasource.dart';
import '../providers/weekend_provider.dart';

/// 教材库页面
///
/// 对应网站 weekendElitePc 的 "课程总览 / 教材列表" 入口。
/// - 学科 + 层次 + 阶段 + 出版社 + 版本 共用一套可收起、纵向排列的筛选器
///   (学科选项来自 bookoptionlist.subjectList, 其余来自 bookoptionlist)
/// - 筛选栏与选项与网站保持一致
/// - 服务端仅按 subjectId/classId/searchName 过滤; 阶段/出版社 由 bookName 解析后客户端过滤
/// - 支持右键/长按菜单、多选模式 (与任务页一致)、下载学生版/教师版
class BookListPage extends ConsumerStatefulWidget {
  const BookListPage({super.key});

  @override
  ConsumerState<BookListPage> createState() => _BookListPageState();
}

class _BookListPageState extends ConsumerState<BookListPage> {
  final WeekendRemoteDataSource _remote =
      WeekendRemoteDataSource(getIt<DioClient>());

  // ─── 筛选选项 (来自 bookoptionlist) ───
  List<Map<String, dynamic>> _optTrainTypes = const [];
  List<Map<String, dynamic>> _optSubjects = const [];
  List<Map<String, dynamic>> _optStages = const [];
  List<Map<String, dynamic>> _optPublishers = const [];
  List<Map<String, dynamic>> _optVersions = const [];
  bool _loadingOptions = false;

  // ─── 选中学科 (服务端过滤) ───
  int? _subjectId;

  // ─── 书本数据 ───
  List<Map<String, dynamic>> _rawBooks = [];
  String? _loadedClassId;
  int? _loadedSubjectId;
  bool _loading = false;
  String? _error;

  // ─── 客户端筛选 (阶段/出版社 仅存在于 bookName) ───
  int? _trainTypeFilter; // 层次
  int? _stageFilter; // 阶段
  int? _publisherFilter; // 出版社
  int? _versionFilter; // 版本
  String _searchText = '';
  /// 筛选面板是否展开 (可收起), 默认收起
  bool _filterExpanded = false;

  // ─── 多选模式 ───
  bool _selectable = false;
  Set<String> _selectedBookIds = {};

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeReload();
  }

  // ─── 数据加载 ───

  Future<void> _loadOptions() async {
    if (_loadingOptions) return;
    _loadingOptions = true;
    try {
      final opt = await _remote.getBookOptionList();
      if (!mounted) return;
      setState(() {
        _optTrainTypes = _asList(opt['trainTypeList']);
        _optSubjects = _asList(opt['subjectList']);
        _optStages = _asList(opt['stageList']);
        _optPublishers = _asList(opt['publishingHouseList']);
        _optVersions = _asList(opt['versionList']);
        if (_subjectId == null && _optSubjects.isNotEmpty) {
          _subjectId = _optSubjects.first['id'] as int;
        }
      });
      _maybeReload();
    } catch (e) {
      // 筛选选项缺失不阻断主流程
      debugPrint('教材筛选选项加载失败: $e');
    } finally {
      _loadingOptions = false;
    }
  }

  /// 当学科或班级发生变化 (且已就绪) 时重新拉取书本列表。
  ///
  /// 通过 addPostFrameCallback 延后到 build 之后执行, 避免 didChangeDependencies
  /// 期间直接 setState。
  void _maybeReload() {
    final classId = ref.read(weekendProvider).selectedClassId;
    if (_subjectId == null || classId == null || classId.isEmpty) return;
    if (classId == _loadedClassId && _subjectId == _loadedSubjectId) return;
    _loadedClassId = classId;
    _loadedSubjectId = _subjectId;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _loadBooks());
  }

  Future<void> _loadBooks() async {
    if (_subjectId == null || _loadedClassId == null) return;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _remote.getBookList(
        subjectId: _subjectId.toString(),
        classId: _loadedClassId!,
        searchName: '',
      );
      if (!mounted) return;
      final all = <Map<String, dynamic>>[];
      if (data['openedBookList'] is List) {
        all.addAll(_asList(data['openedBookList']));
      }
      if (data['bookInfoList'] is List) {
        for (final grp in data['bookInfoList']) {
          if (grp is Map<String, dynamic> && grp['bookList'] is List) {
            all.addAll(_asList(grp['bookList']));
          }
        }
      }
      setState(() {
        _rawBooks = all;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _asList(dynamic v) =>
      (v is List ? v.whereType<Map<String, dynamic>>().toList() : const []);

  // ─── bookName 解析 (阶段/出版社) ───

  /// 阶段: 必修 / 选必 / 复习
  static String _parseStage(String name) {
    if (name.contains('选择性必修')) return '选必';
    if (name.contains('必修')) return '必修';
    if (name.contains('复习') || name.contains('总复习')) return '复习';
    return '';
  }

  /// 出版社: 提取 【xxx版】 中的内容
  static String? _parsePublisher(String name) {
    final m = RegExp(r'【(.*?版)】').firstMatch(name);
    return m?.group(1);
  }

  /// 出版社匹配: 人教A版/人教B版 归入 "人教版"
  static bool _publisherMatches(String? parsed, Map<String, dynamic> opt) {
    if (parsed == null) return false;
    final optName = opt['name'].toString();
    if (parsed == optName) return true;
    if (optName == '人教版' && parsed.startsWith('人教')) return true;
    return false;
  }

  String? _optStageName(int id) {
    for (final o in _optStages) {
      if (o['id'] == id) return o['name'].toString();
    }
    return null;
  }

  // ─── 客户端筛选结果 ───

  List<Map<String, dynamic>> get _filtered {
    final stageName = _stageFilter == null ? null : _optStageName(_stageFilter!);
    final pubOpt = _publisherFilter == null
        ? null
        : _optPublishers.firstWhere(
            (o) => o['id'] == _publisherFilter,
            orElse: () => const <String, dynamic>{},
          );
    return _rawBooks.where((b) {
      final name = (b['bookName'] ?? '').toString();
      if (_trainTypeFilter != null &&
          (b['trainingType'] as int? ?? 0) != _trainTypeFilter) {
        return false;
      }
      if (stageName != null && _parseStage(name) != stageName) return false;
      if (pubOpt != null && pubOpt.isNotEmpty) {
        if (!_publisherMatches(_parsePublisher(name), pubOpt)) return false;
      }
      if (_versionFilter != null &&
          (b['version'] as int? ?? 0) != _versionFilter) {
        return false;
      }
      if (_searchText.isNotEmpty && !name.contains(_searchText)) return false;
      return true;
    }).toList();
  }

  bool get _hasActiveFilter =>
      _trainTypeFilter != null ||
      _stageFilter != null ||
      _publisherFilter != null ||
      _versionFilter != null ||
      _searchText.isNotEmpty;

  /// 仅统计筛选面板内 (学科/层次/阶段/出版社/版本) 的激活项, 不含搜索框。
  int get _activeFilterCount =>
      (_subjectId == null ? 1 : 0) +
      (_trainTypeFilter != null ? 1 : 0) +
      (_stageFilter != null ? 1 : 0) +
      (_publisherFilter != null ? 1 : 0) +
      (_versionFilter != null ? 1 : 0);

  void _onSubjectChange(int? id) {
    if (id == _subjectId) return;
    setState(() => _subjectId = id);
    if (id == null) {
      // 学科选 "不限" 时, 服务端无法按学科过滤, 直接清空列表
      _rawBooks = [];
    }
    _maybeReload();
  }

  void _onFilterTap(String kind, int? id) {
    setState(() {
      switch (kind) {
        case 'train':
          _trainTypeFilter = id;
          break;
        case 'stage':
          _stageFilter = id;
          break;
        case 'pub':
          _publisherFilter = id;
          break;
        case 'ver':
          _versionFilter = id;
          break;
      }
    });
  }

  void _clearFilters() {
    setState(() {
      _trainTypeFilter = null;
      _stageFilter = null;
      _publisherFilter = null;
      _versionFilter = null;
      _searchText = '';
    });
  }

  /// 刷新当前筛选条件下的书本列表 (AppBar 刷新按钮)
  ///
  /// 强制重载: 无论是否已加载过当前学科/班级都重新拉取, 完成后提示结果。
  Future<void> _reload() async {
    final classId = ref.read(weekendProvider).selectedClassId;
    if (_subjectId == null || classId == null || classId.isEmpty) {
      if (mounted) {
        showAppSnackBar(
          ScaffoldMessenger.of(context),
          '暂无可刷新的教材',
        );
      }
      return;
    }
    if (_loading) return;
    _loadedClassId = classId;
    _loadedSubjectId = _subjectId;
    final messenger = ScaffoldMessenger.of(context);
    await _loadBooks();
    if (!mounted) return;
    showAppSnackBar(
      messenger,
      _error == null ? '刷新完成' : '刷新失败: $_error',
      isError: _error != null,
    );
  }

  // ─── 多选 ───

  void _enterMultiSelect(String bookId) {
    setState(() {
      _selectable = true;
      _selectedBookIds.add(bookId);
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _selectable = false;
      _selectedBookIds.clear();
    });
  }

  void _toggleSelection(String bookId) {
    setState(() {
      if (_selectedBookIds.contains(bookId)) {
        _selectedBookIds.remove(bookId);
      } else {
        _selectedBookIds.add(bookId);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selectedBookIds.length == _filtered.length) {
        _selectedBookIds.clear();
      } else {
        _selectedBookIds =
            _filtered.map((b) => b['bookId'].toString()).toSet();
      }
    });
  }

  void _invertSelection() {
    setState(() {
      final all = _filtered.map((b) => b['bookId'].toString()).toSet();
      _selectedBookIds = all.difference(_selectedBookIds);
    });
  }

  // ─── 下载 ───

  Future<void> _downloadBook(Map<String, dynamic> book,
      {required bool teacher}) async {
    final url = teacher
        ? (book['fileUrlTeacher']?.toString() ?? '')
        : (book['fileUrl']?.toString() ?? '');
    if (url.isEmpty) {
      _toast(teacher ? '该教材暂无教师版' : '该教材暂无学生版');
      return;
    }
    await _runBookDownload([book], teacher: teacher);
  }

  Future<void> _downloadSelected({required bool teacher}) async {
    final books = _filtered
        .where((b) => _selectedBookIds.contains(b['bookId'].toString()))
        .toList();
    if (books.isEmpty) return;
    await _runBookDownload(books, teacher: teacher);
  }

  /// 执行教材下载, 弹出进度/日志弹窗 (与其他下载功能一致)
  ///
  /// 通过 [DownloadService.downloadBooks] 逐本下载, 由 [TaskProgressDialog]
  /// 展示每本进度、日志与停止按钮。
  Future<void> _runBookDownload(List<Map<String, dynamic>> books,
      {required bool teacher}) async {
    final version = teacher ? '教师版' : '学生版';
    final service = DownloadService(client: getIt<DioClient>());
    final dialogKey = GlobalKey<TaskProgressDialogState>();
    final items = (books)
        .map((b) => TaskProgressItem(
              title: (b['bookName'] ?? '教材').toString(),
              subtitle: version,
            ))
        .toList();

    if (!mounted) return;
    var dismissed = false;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: '教材下载 ($version)',
      dialogKey: dialogKey,
      onStop: () {
        dismissed = true;
        service.cancel();
        service.dispose();
      },
    );

    await service.downloadBooks(
      books,
      teacher: teacher,
      onItemUpdate: (index, item) {
        if (index < items.length) {
          items[index].state = item.state;
          items[index].progress = item.progress;
          items[index].message = item.message;
          items[index].error = item.error;
        }
      },
    );

    service.dispose();
    if (!dismissed) {
      dialogKey.currentState?.markFinished();
    }
  }

  void _showBatchDownloadDialog() {
    showDialog(
      context: context,
      useRootNavigator: true,
      builder: (_) => AlertDialog(
        title: Text('下载所选 (${_selectedBookIds.length} 本)'),
        content: const Text('请选择要下载的版本：'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              _downloadSelected(teacher: false);
            },
            child: const Text('学生版'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              _downloadSelected(teacher: true);
            },
            child: const Text('教师版'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ─── 详情 ───

  void _openBookDetail(Map<String, dynamic> book) {
    final name = (book['bookName'] ?? '未命名').toString();
    final cover = (book['coverImage'] ?? '').toString();
    final desc = (book['description'] ?? '').toString();
    final chapterCount = book['chapterCount'] ?? 0;
    final trainType = book['trainingType'] as int? ?? 0;
    final trainName =
        trainType == 2 ? '培尖' : (trainType == 1 ? '培优' : '—');
    final versionName = (book['versionName'] ?? '').toString();
    final publisher = _parsePublisher(name) ?? '—';
    final stage = _parseStage(name);
    final hasStu = (book['fileUrl']?.toString().isNotEmpty ?? false);
    final hasTea = (book['fileUrlTeacher']?.toString().isNotEmpty ?? false);

    showDialog(
      context: context,
      useRootNavigator: true,
      builder: (_) => AlertDialog(
        title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cover.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      cover,
                      height: 160,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      headers: const {'Referer': 'https://web.ewt360.com/'},
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                const SizedBox(height: 12),
                _metaRow('培训类型', trainName),
                _metaRow('阶段', stage.isEmpty ? '—' : stage),
                _metaRow('出版社', publisher),
                _metaRow('版本', versionName.isEmpty ? '—' : versionName),
                _metaRow('章节数', '$chapterCount'),
                const SizedBox(height: 8),
                if (desc.isNotEmpty)
                  Text(desc, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Text('关闭'),
          ),
          if (hasStu)
            TextButton(
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
                _downloadBook(book, teacher: false);
              },
              child: const Text('下载学生版'),
            ),
          if (hasTea)
            TextButton(
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
                _downloadBook(book, teacher: true);
              },
              child: const Text('下载教师版'),
            ),
        ],
      ),
    );
  }

  Widget _metaRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Text('$k：', style: const TextStyle(fontWeight: FontWeight.w600)),
            Expanded(child: Text(v)),
          ],
        ),
      );

  // ─── 右键/长按菜单 ───

  List<ContextMenuItem> _menuFor(Map<String, dynamic> book) {
    final bookId = book['bookId'].toString();
    if (_selectable) {
      return [
        ContextMenuItem(
          id: 'exit',
          label: '退出多选',
          icon: Icons.close,
          onTap: _exitMultiSelect,
        ),
        ContextMenuItem(
          id: 'all',
          label: _selectedBookIds.length == _filtered.length
              ? '取消全选'
              : '全选',
          icon: Icons.select_all,
          onTap: _selectAll,
        ),
        ContextMenuItem(
          id: 'invert',
          label: '反选',
          icon: Icons.flip,
          onTap: _invertSelection,
        ),
        ContextMenuItem.divider(),
        ContextMenuItem(
          id: 'dl_stu',
          label: '下载学生版',
          icon: Icons.download,
          onTap: () => _downloadBook(book, teacher: false),
        ),
        ContextMenuItem(
          id: 'dl_tea',
          label: '下载教师版',
          icon: Icons.download,
          onTap: () => _downloadBook(book, teacher: true),
        ),
      ];
    }
    return [
      ContextMenuItem(
        id: 'detail',
        label: '查看详情',
        icon: Icons.info_outline,
        onTap: () => _openBookDetail(book),
      ),
      ContextMenuItem(
        id: 'multi',
        label: '多选',
        icon: Icons.checklist,
        onTap: () => _enterMultiSelect(bookId),
      ),
      ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'dl_stu',
        label: '下载学生版',
        icon: Icons.download,
        enabled: book['fileUrl']?.toString().isNotEmpty ?? false,
        onTap: () => _downloadBook(book, teacher: false),
      ),
      ContextMenuItem(
        id: 'dl_tea',
        label: '下载教师版',
        icon: Icons.download,
        enabled: book['fileUrlTeacher']?.toString().isNotEmpty ?? false,
        onTap: () => _downloadBook(book, teacher: true),
      ),
    ];
  }

  // ─── 构建 ───

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weekend = ref.watch(weekendProvider);
    return Scaffold(
      appBar: AppBar(
        leading: _selectable
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: '退出多选',
                onPressed: _exitMultiSelect,
              )
            : null,
        title: _selectable
            ? Text('已选 ${_selectedBookIds.length} 项')
            : const Text('教材库'),
        actions: _selectable
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: _selectedBookIds.length == _filtered.length
                      ? '取消全选'
                      : '全选',
                  onPressed: _selectAll,
                ),
                IconButton(
                  icon: const Icon(Icons.flip),
                  tooltip: '反选',
                  onPressed: _invertSelection,
                ),
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: '下载所选',
                  onPressed: _showBatchDownloadDialog,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: '多选',
                  onPressed: _filtered.isEmpty
                      ? null
                      : () => _enterMultiSelect(_filtered.first['bookId'].toString()),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: _reload,
                ),
              ],
      ),
      body: Column(
        children: [
          _buildFilterPanel(theme),
          _buildToolbar(theme, weekend),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  /// 可收起的筛选面板: 学科 + 层次 + 阶段 + 出版社 + 版本 纵向排列,
  /// 每个筛选器使用完全一致的 [_filterGroup] 样式 (含 "不限" + 选项)。
  Widget _buildFilterPanel(ThemeData theme) {
    final activeCount = _activeFilterCount;
    final groups = <Widget>[
      _filterGroup(theme, '学科', _optSubjects, _subjectId, _onSubjectChange,
          showAll: false),
      _filterGroup(theme, '层次', _optTrainTypes, _trainTypeFilter,
          (v) => _onFilterTap('train', v)),
      _filterGroup(theme, '阶段', _optStages, _stageFilter,
          (v) => _onFilterTap('stage', v)),
      _filterGroup(theme, '出版社', _optPublishers, _publisherFilter,
          (v) => _onFilterTap('pub', v)),
      _filterGroup(theme, '版本', _optVersions, _versionFilter,
          (v) => _onFilterTap('ver', v)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _filterExpanded = !_filterExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  _filterExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
                const SizedBox(width: 6),
                const Text('筛选选项',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (activeCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('$activeCount 项',
                        style: theme.textTheme.labelSmall),
                  ),
              ],
            ),
          ),
        ),
        if (_filterExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: groups,
            ),
          ),
      ],
    );
  }

  /// 单个筛选器分组: 带边框的容器, 顶部是筛选名称, 下方是 "不限" + 各选项的
  /// [FilterChip], 超出宽度时自动换行。学科与其他筛选器共用此组件。
  ///
  /// [showAll] 为 false 时不渲染 "不限" (用于学科: 学科为必选项, 选 "不限"
  /// 会导致 subjectId 为空、无法拉取数据)。
  Widget _filterGroup(
    ThemeData theme,
    String label,
    List<Map<String, dynamic>> options,
    int? selectedId,
    ValueChanged<int?> onChanged, {
    bool showAll = true,
  }) {
    final chips = <Widget>[
      if (showAll)
        FilterChip(
          label: const Text('不限'),
          selected: selectedId == null,
          onSelected: (_) => onChanged(null),
        ),
      for (final o in options)
        FilterChip(
          label: Text(o['name'].toString()),
          selected: selectedId == o['id'],
          onSelected: (_) => onChanged(o['id'] as int),
        ),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: chips,
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme, WeekendState weekend) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: '搜索教材名称',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (v) => setState(() => _searchText = v),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: weekend.selectedClassId,
            hint: const Text('班级'),
            items: weekend.classList.map<DropdownMenuItem<String>>((c) {
              final m = c as Map<String, dynamic>;
              final id = m['classId']?.toString() ??
                  m['id']?.toString() ??
                  '';
              final name = m['className']?.toString() ??
                  m['name']?.toString() ??
                  '未知班级';
              return DropdownMenuItem(value: id, child: Text(name));
            }).toList(),
            onChanged: (id) {
              if (id == null) return;
              final m = weekend.classList.firstWhere((c) {
                final cm = c as Map<String, dynamic>;
                return (cm['classId']?.toString() ??
                        cm['id']?.toString() ??
                        '') ==
                    id;
              }) as Map<String, dynamic>;
              final name = m['className']?.toString() ??
                  m['name']?.toString() ??
                  '未知班级';
              ref.read(weekendProvider.notifier).selectClass(id, name);
              _maybeReload();
            },
          ),
          const SizedBox(width: 8),
          if (_hasActiveFilter)
            TextButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.clear_all),
              label: const Text('清空筛选'),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_rawBooks.isEmpty) {
      return const Center(child: Text('暂无教材数据'));
    }
    final list = _filtered;
    if (list.isEmpty) {
      return const Center(child: Text('没有符合筛选条件的教材'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.68,
      ),
      itemCount: list.length,
      itemBuilder: (context, index) => _buildBookCard(list[index], theme),
    );
  }

  Widget _buildBookCard(Map<String, dynamic> book, ThemeData theme) {
    final bookId = book['bookId'].toString();
    final selected = _selectedBookIds.contains(bookId);
    final cover = (book['coverImage'] ?? '').toString();
    final name = (book['bookName'] ?? '未命名').toString();
    final chapterCount = book['chapterCount'] ?? 0;
    final trainType = book['trainingType'] as int? ?? 0;
    final trainName =
        trainType == 2 ? '培尖' : (trainType == 1 ? '培优' : '');

    return Card(
      clipBehavior: Clip.antiAlias,
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: ContextMenuRegion(
        menuBuilder: (context) => _menuFor(book),
        child: InkWell(
          onTap: () {
            if (_selectable) {
              _toggleSelection(bookId);
            } else {
              _openBookDetail(book);
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: cover.isNotEmpty
                    ? Image.network(
                        cover,
                        fit: BoxFit.cover,
                        headers: const {
                          'Referer': 'https://web.ewt360.com/'
                        },
                        errorBuilder: (_, _, _) => const Center(
                          child: Icon(Icons.menu_book, size: 40),
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.menu_book, size: 40),
                      ),
              ),
              Container(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (trainName.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              trainName,
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        Text(
                          '$chapterCount 章',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
