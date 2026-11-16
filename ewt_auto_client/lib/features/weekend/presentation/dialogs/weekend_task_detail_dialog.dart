/// 周培优任务详情弹窗：展示任务详情与视频信息，仅视频类型任务通过
/// getPlayerToken + getExternalVideoInfo 加载视频源，点击"播放视频"时
/// 经 VideoPlayLauncher 解析真实地址并启动播放/后台上报。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:ewt_auto_client/features/player/data/datasources/player_remote_datasource.dart';
import 'package:ewt_auto_client/features/player/presentation/services/video_play_launcher.dart';

/// 周培优任务详情弹窗
///
/// 点击任务卡片后打开，展示任务详情 + 视频信息
/// 对应 Python: gui/interfaces/weekly.py 中的任务详情展示
class WeekendTaskDetailDialog extends StatefulWidget {
  /// 任务数据 (courseDetail 返回的 task item)
  final Map<String, dynamic> taskData;
  final String chapterName;

  /// 当前章节 ID (留作扩展, 页面级"周练错题解析"在任务列表页实现)
  final String chapterId;

  /// 当前班级 ID (留作扩展)
  final String classId;

  /// 用户会话 (提供时启用播放视频 + 后台进度上报)
  final UserSession? userSession;

  const WeekendTaskDetailDialog({
    super.key,
    required this.taskData,
    this.chapterName = '',
    this.chapterId = '',
    this.classId = '',
    this.userSession,
  });

  @override
  State<WeekendTaskDetailDialog> createState() =>
      _WeekendTaskDetailDialogState();
}

class _WeekendTaskDetailDialogState extends State<WeekendTaskDetailDialog> {
  bool _loading = true;

  /// getExternalVideoInfo 的完整响应 (含 videoList), 供点击"播放视频"时
  /// 调用 [VideoSourceResolver] 解析真实播放地址 (对齐 CourseDetailDialog)。
  Map<String, dynamic> _videoInfo = {};

  /// 是否有可解析的视频源 (videoList 非空)
  bool _hasVideoSource = false;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  /// 加载视频源信息 (对齐 CourseDetailDialog._loadDetail 中的视频源获取逻辑)
  ///
  /// 周培优任务通过 [PlayerRemoteDataSource.getPlayerToken] +
  /// [PlayerRemoteDataSource.getExternalVideoInfo] 获取视频源信息,
  /// 然后在点击"播放视频"时由 [VideoSourceResolver] 解析真实地址。
  /// 不再使用 [WeekendRemoteDataSource.getVideoList] (仅返回元数据, 无可播放 URL)。
  Future<void> _loadDetail() async {
    final task = widget.taskData;
    final contentType = task['contentType'];
    // 仅视频类型 (1=主课/微专题, 4=微专题) 加载视频源
    if (contentType != 1 && contentType != 4) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final lessonId = (task['lessonId'] ?? task['contentId'] ?? '').toString();
    if (lessonId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final schoolId = widget.userSession?.schoolId ?? '';

    try {
      final client = PlayerRemoteDataSource(getIt<DioClient>());

      // 获取视频源信息 (暂不解析真实地址, 点击"播放视频"时再解析)
      Map<String, dynamic> videoInfo = {};
      bool hasSource = false;
      try {
        final token = await client.getPlayerToken(
          schoolId: schoolId,
          lessonId: lessonId,
        );
        if (token.isNotEmpty) {
          videoInfo = await client.getExternalVideoInfo(
            lessonId: lessonId,
            videoToken: token,
          );
          final videoList =
              (videoInfo['videoList'] as List<dynamic>?) ?? [];
          hasSource = videoList.isNotEmpty;
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _videoInfo = videoInfo;
          _hasVideoSource = hasSource;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = widget.taskData;
    final title = (task['taskTitle'] ??
            task['taskName'] ??
            task['name'] ??
            task['title'] ??
            '任务详情')
        .toString();

    return Dialog(
      child: ConstrainedBox(
        // 高度自适应屏幕: 小屏/横屏不超屏高 80%, 防止内容溢出
        constraints: BoxConstraints(
          maxWidth: 580,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme, title),
            const Divider(height: 1),
            Flexible(child: _buildContent(theme)),
            const Divider(height: 1),
            _buildActions(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, String title) {
    final typeName =
        (widget.taskData['contentTypeName'] ?? '').toString();
    final subtitle = [
      if (widget.chapterName.isNotEmpty) widget.chapterName,
      if (typeName.isNotEmpty) typeName,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final task = widget.taskData;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // 基本信息
        _sectionTitle(theme, '基本信息'),
        const SizedBox(height: 8),
        _infoGrid(theme, [
          ('类型', (task['contentTypeName'] ?? '-').toString()),
          ('课程ID', (task['courseId'] ?? '-').toString()),
          ('讲次ID', (task['lessonId'] ?? '-').toString()),
          if (task['paperId'] != null)
            ('试卷ID', task['paperId'].toString()),
          ('资源类型', (task['resourceBizType'] ?? '-').toString()),
        ]),

        const SizedBox(height: 20),

        // 完成状态
        _sectionTitle(theme, '完成状态'),
        const SizedBox(height: 8),
        _buildStatus(theme),

        // 进度
        if (task['taskProgress'] != null) ...[
          const SizedBox(height: 12),
          _buildProgress(theme),
        ],

        // 视频源加载状态
        if (_loading) ...[
          const SizedBox(height: 20),
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ] else if (_hasVideoSource) ...[
          const SizedBox(height: 20),
          _sectionTitle(theme, '视频源'),
          const SizedBox(height: 4),
          Text(
            '已加载视频源, 点击下方"播放视频"开始播放 (含进度上报)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],

        // 链接
        if (_hasLinks()) ...[
          const SizedBox(height: 20),
          _sectionTitle(theme, '链接'),
          const SizedBox(height: 8),
          if ((task['lessonContentUrl']?.toString() ?? '').isNotEmpty)
            _linkRow(theme, '课程内容', task['lessonContentUrl'].toString()),
          if ((task['paperContentUrl']?.toString() ?? '').isNotEmpty)
            _linkRow(theme, '试卷内容', task['paperContentUrl'].toString()),
        ],
      ],
    );
  }

  Widget _buildStatus(ThemeData theme) {
    final task = widget.taskData;
    final contentType = task['contentType'];

    // 视频类型看 lessonIsComplete，试卷类型看 paperIsComplete
    final isComplete = (contentType == 1 || contentType == 4)
        ? task['lessonIsComplete'] == true || task['lessonIsComplete'] == 1
        : task['paperIsComplete'] == true || task['paperIsComplete'] == 1;

    return Row(
      children: [
        Icon(
          isComplete ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 18,
          color: isComplete ? Colors.green : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Text(
          isComplete ? '已完成' : '未完成',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildProgress(ThemeData theme) {
    final progress = widget.taskData['taskProgress'];
    final value = progress is num
        ? progress.toDouble()
        : double.tryParse('$progress') ?? 0.0;
    final clamped = value.clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '进度: ${(clamped * 100).toStringAsFixed(0)}%',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: clamped,
            minHeight: 4,
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) {
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _infoGrid(ThemeData theme, List<(String, String)> items) {
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: items
          .map((item) => SizedBox(
                width: 180,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item.$1}: ',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item.$2,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ))
          .toList(),
    );
  }

  Widget _linkRow(ThemeData theme, String label, String url) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: url));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$label链接已复制')),
          );
        },
        child: Row(
          children: [
            Icon(Icons.link, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              '复制$label',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    final isVideo = widget.taskData['contentType'] == 1 ||
        widget.taskData['contentType'] == 4;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (isVideo && _hasVideoSource)
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('播放视频'),
              onPressed: () => _onPlayVideo(),
            ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 点击"播放视频": 通过 [VideoPlayLauncher] 解析真实地址 + 构建上报会话 + 跳转播放页
  ///
  /// 对齐 CourseDetailDialog._onPlayVideo, 但使用统一的 VideoPlayLauncher
  /// 同时完成: 视频源解析 + BFE 会话获取 + 后台进度上报启动 + 日志侧边栏。
  Future<void> _onPlayVideo() async {
    final task = widget.taskData;
    final lessonId =
        (task['lessonId'] ?? task['contentId'] ?? task['id'] ?? '').toString();
    final videoId = (task['videoId'] ?? '').toString();
    final taskId = (task['taskId'] ?? '').toString();
    final contentType = task['contentType'] is int
        ? task['contentType'] as int
        : int.tryParse(task['contentType']?.toString() ?? '') ?? 1;
    final duration = task['duration'] is int
        ? task['duration'] as int
        : int.tryParse(task['duration']?.toString() ?? '') ?? 0;
    final title = (task['taskTitle'] ??
            task['title'] ??
            task['taskName'] ??
            task['name'] ??
            '视频播放')
        .toString();

    await VideoPlayLauncher.start(
      context: context,
      videoInfo: _videoInfo,
      lessonId: lessonId,
      homeworkId: '', // 周培优无 homeworkId
      videoId: videoId,
      taskId: taskId,
      contentType: contentType,
      duration: duration,
      title: title,
      userSession: widget.userSession,
    );
  }

  bool _hasLinks() {
    final task = widget.taskData;
    return (task['lessonContentUrl']?.toString() ?? '').isNotEmpty ||
        (task['paperContentUrl']?.toString() ?? '').isNotEmpty;
  }
}