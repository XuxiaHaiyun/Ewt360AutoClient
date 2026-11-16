/// 作业级任务筛选弹窗，按状态/学科/类型筛选批量任务要拉取的作业范围（作用于 getHomeworkList）。
/// 课程级过滤由各功能专属配置页处理；show 返回 TaskFilterConfig，取消返回 null。
library;

import 'package:flutter/material.dart';

import '../../domain/entities/task_filter_config.dart';
import '../../presentation/providers/homework_provider.dart';

/// 作业级任务筛选弹窗
///
/// 在批量任务执行前, 按 状态/学科/类型 筛选作业列表。
/// 筛选条件作用于 getHomeworkList API, 决定拉取哪些作业。
///
/// 课程级过滤 (类型/学科/已完成) 由各功能专属配置页处理:
/// - 进度上报: [ReportConfigPage]
/// - 试题答案: [AnswerConfigPage]
/// - 下载视频: [DownloadVideoConfigDialog]
/// - 下载试题: [DownloadPaperConfigDialog]
class TaskFilterDialog extends StatefulWidget {
  final String taskType;

  const TaskFilterDialog({super.key, required this.taskType});

  /// 显示筛选弹窗, 返回配置 (取消返回 null)
  static Future<TaskFilterConfig?> show(
    BuildContext context, {
    required String taskType,
  }) {
    return showDialog<TaskFilterConfig>(
      context: context,
      builder: (_) => TaskFilterDialog(taskType: taskType),
    );
  }

  @override
  State<TaskFilterDialog> createState() => _TaskFilterDialogState();
}

class _TaskFilterDialogState extends State<TaskFilterDialog> {
  int? _status = 2; // 默认进行中
  int? _subject;
  int? _type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return AlertDialog(
      icon: Icon(Icons.filter_list, color: cs.primary),
      title: Text('${widget.taskType} - 任务筛选'),
      content: SizedBox(
        width: 440,
        // 内容可能超出小屏高度, 包滚动容器防止溢出
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Text(
              '选择要拉取的作业范围 (用于过滤作业列表)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // ─── 作业状态 ───
            Text(
              '作业状态',
              style: theme.textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                (null, '全部'),
                ...statusFilterOptions,
              ].map((opt) {
                final (value, label) = opt;
                return FilterChip(
                  label: Text(label),
                  selected: _status == value,
                  onSelected: (_) => setState(() => _status = value),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // ─── 学科 ───
            Text(
              '作业学科',
              style: theme.textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 0,
              children: subjectFilterOptions.map((opt) {
                final (value, label) = opt;
                return FilterChip(
                  label: Text(label),
                  selected: _subject == value,
                  onSelected: (_) => setState(() => _subject = value),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // ─── 作业类型 ───
            Text(
              '作业类型',
              style: theme.textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: typeFilterOptions.map((opt) {
                final (value, label) = opt;
                return FilterChip(
                  label: Text(label),
                  selected: _type == value,
                  onSelected: (_) => setState(() => _type = value),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
          ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            TaskFilterConfig(status: _status, subject: _subject, type: _type),
          ),
          child: const Text('下一步'),
        ),
      ],
    );
  }
}
