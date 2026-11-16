/// 下载配置弹窗（视频/试题共用），配置视频线路（自动/腾讯云/阿里云）与课程级过滤选项。
/// show 返回 DownloadConfig，取消返回 null。
library;

import 'package:flutter/material.dart';

import '../../../answer/domain/entities/answer_filter_config.dart';
import '../../../player/domain/services/video_source_resolver.dart';
import '../../domain/entities/download_config.dart';

/// 下载配置弹窗 (视频/试题共用)
///
/// 仅显示课程级过滤选项。试题 PDF 走服务端生成, 无字体配置。
///
/// 对应 Python: gui/dialogs 中下载任务的配置入口
class DownloadConfigDialog extends StatefulWidget {
  /// 'video' = 下载视频, 'paper' = 下载试题
  final String mode;

  const DownloadConfigDialog({super.key, required this.mode});

  /// 显示配置弹窗, 返回配置 (取消返回 null)
  static Future<DownloadConfig?> show(
    BuildContext context, {
    required String mode,
  }) {
    return showDialog<DownloadConfig>(
      context: context,
      builder: (_) => DownloadConfigDialog(mode: mode),
    );
  }

  @override
  State<DownloadConfigDialog> createState() => _DownloadConfigDialogState();
}

class _DownloadConfigDialogState extends State<DownloadConfigDialog> {
  bool get _isPaper => widget.mode == 'paper';

  // ─── 视频线路 (仅视频下载显示) ───
  VideoLine _videoLine = VideoLine.auto;

  static String _lineLabel(VideoLine l) => switch (l) {
        VideoLine.auto => '自动',
        VideoLine.tencent => '腾讯云',
        VideoLine.aliyun => '阿里云',
      };

  // ─── 课程级过滤 (不再展示选项, 沿用默认值) ───
  final bool _filterNoHomework = true;
  final bool _filterCompleted = false;
  final Set<int?> _selectedTypes = {null};
  final Set<String> _selectedSubjects = Set<String>.from(kCourseSubjects);

  void _toggleType(int? value, bool checked) {
    setState(() {
      if (value == null) {
        if (checked) {
          _selectedTypes
            ..clear()
            ..add(null);
        } else {
          if (_selectedTypes.length > 1) _selectedTypes.remove(null);
        }
      } else {
        if (checked) {
          _selectedTypes
            ..remove(null)
            ..add(value);
        } else {
          _selectedTypes.remove(value);
          if (_selectedTypes.isEmpty) _selectedTypes.add(null);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = _isPaper ? '下载试题配置' : '下载视频配置';

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_isPaper) ...[
                // ─── 视频线路 ───
                Text(
                  '下载线路',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '自动优先腾讯云, 失败回退阿里云',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<VideoLine>(
                  segments: [
                    for (final l in VideoLine.values)
                      ButtonSegment(
                        value: l,
                        label: Text(_lineLabel(l)),
                        icon: l == _videoLine
                            ? const Icon(Icons.check, size: 16)
                            : null,
                      ),
                  ],
                  selected: {_videoLine},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setState(() => _videoLine = s.first),
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
              if (_isPaper) const Divider(height: 24),

              // ─── 课程类型 ───
              Text(
                '下载课程类型 (至少选择一项)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 0,
                children: kCourseTypeOptions.map((opt) {
                  final checked = _selectedTypes.contains(opt.value);
                  return FilterChip(
                    label: Text(opt.label),
                    selected: checked,
                    onSelected: (_) => _toggleType(opt.value, !checked),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),

              // ─── 课程学科 ───
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '下载课程学科 (至少选择一项)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() {
                      if (_selectedSubjects.length == kCourseSubjects.length) {
                        _selectedSubjects.clear();
                      } else {
                        _selectedSubjects
                          ..clear()
                          ..addAll(kCourseSubjects);
                      }
                    }),
                    icon: Icon(
                      _selectedSubjects.length == kCourseSubjects.length
                          ? Icons.deselect_outlined
                          : Icons.select_all_outlined,
                      size: 18,
                    ),
                    label: Text(
                      _selectedSubjects.length == kCourseSubjects.length
                          ? '取消全选'
                          : '全选',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 0,
                children: kCourseSubjects.map((name) {
                  final checked = _selectedSubjects.contains(name);
                  return FilterChip(
                    label: Text(name),
                    selected: checked,
                    onSelected: (_) => setState(() {
                      if (checked) {
                        _selectedSubjects.remove(name);
                      } else {
                        _selectedSubjects.add(name);
                      }
                    }),
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
          onPressed: _onConfirm,
          child: const Text('开始下载'),
        ),
      ],
    );
  }

  void _onConfirm() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (_selectedTypes.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('请至少选择一个课程类型')),
      );
      return;
    }
    if (_selectedSubjects.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('请至少选择一个课程学科')),
      );
      return;
    }

    Navigator.pop(
      context,
      DownloadConfig(
        filterConfig: AnswerFilterConfig(
          filterNoHomework: _filterNoHomework,
          filterCompleted: _filterCompleted,
          selectedTypes: _selectedTypes.toList(),
          selectedSubjects: _selectedSubjects.toList(),
        ),
        videoLine: _videoLine,
      ),
    );
  }
}
