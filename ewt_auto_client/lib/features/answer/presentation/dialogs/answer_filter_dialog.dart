/// 试题答案过滤配置弹窗：过滤无作业/已完成课程，多选获取答案的课程类型与学科。
/// 过滤逻辑由调用方在任务启动前预先应用，避免获取无用数据；取消时返回 null。
library;

import 'package:flutter/material.dart';

import '../../domain/entities/answer_filter_config.dart';

/// 试题答案过滤配置弹窗
///
/// 对应 Python: gui/dialogs/answer_filter.py AnswerFilterDialog
///
/// 在点击"试题答案"且选完方案后弹出 (此时未发送数据包), 让用户配置:
/// - 是否过滤无作业课程 (taskId 为空)
/// - 是否过滤已完成作业课程 (homeworkFinishStatus == 1)
/// - 获取答案的课程类型 (多选: 全部/视频/试卷/FM/资讯/板报/测评/课后习题/校本视频/校本试卷/...)
/// - 获取答案的课程学科 (多选: 15 个学科)
///
/// 过滤逻辑由调用方在任务启动前预先应用, 避免获取无用数据。
class AnswerFilterDialog extends StatefulWidget {
  const AnswerFilterDialog({super.key});

  /// 显示过滤配置弹窗, 返回配置 (取消返回 null)
  static Future<AnswerFilterConfig?> show(BuildContext context) {
    return showDialog<AnswerFilterConfig>(
      context: context,
      builder: (_) => const AnswerFilterDialog(),
    );
  }

  @override
  State<AnswerFilterDialog> createState() => _AnswerFilterDialogState();
}

class _AnswerFilterDialogState extends State<AnswerFilterDialog> {
  bool _filterNoHomework = true;
  bool _filterCompleted = false;

  /// 选中的 contentType 集合 (null 表示"全部")
  final Set<int?> _selectedTypes = {null};

  /// 选中的学科集合
  final Set<String> _selectedSubjects = Set<String>.from(kCourseSubjects);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('试题答案配置'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── 过滤选项 ───
              Text(
                '过滤选项',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              _buildCheckboxTile(
                label: '过滤无作业课程 (无题目且无导学案)',
                value: _filterNoHomework,
                onChanged: (v) => setState(() => _filterNoHomework = v ?? true),
              ),
              _buildCheckboxTile(
                label: '过滤已完成课程 (finished/taskStatus==30)',
                value: _filterCompleted,
                onChanged: (v) => setState(() => _filterCompleted = v ?? false),
              ),
              const Divider(height: 24),

              // ─── 课程类型 ───
              Text(
                '获取答案的课程类型 (至少选择一项)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 0,
                children: kCourseTypeOptions.map((opt) {
                  final checked = _selectedTypes.contains(opt.value);
                  return _buildFilterChip(
                    label: opt.label,
                    checked: checked,
                    onToggle: () => _toggleType(opt.value, !checked),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // ─── 课程学科 ───
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '获取答案的课程学科 (至少选择一项)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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
                  return _buildFilterChip(
                    label: name,
                    checked: checked,
                    onToggle: () => setState(() {
                      if (checked) {
                        _selectedSubjects.remove(name);
                      } else {
                        _selectedSubjects.add(name);
                      }
                    }),
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
          child: const Text('确认'),
        ),
      ],
    );
  }

  Widget _buildCheckboxTile({
    required String label,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: onChanged,
              visualDensity: VisualDensity.compact,
            ),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool checked,
    required VoidCallback onToggle,
  }) {
    return FilterChip(
      label: Text(label),
      selected: checked,
      onSelected: (_) => onToggle(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  /// 切换课程类型选择 (互斥: "全部" 与其他)
  void _toggleType(int? value, bool checked) {
    setState(() {
      if (value == null) {
        // 选中"全部" -> 清空其他
        if (checked) {
          _selectedTypes
            ..clear()
            ..add(null);
        } else {
          // 不允许取消最后一个
          if (_selectedTypes.length > 1) _selectedTypes.remove(null);
        }
      } else {
        // 选中具体类型 -> 移除"全部"
        if (checked) {
          _selectedTypes
            ..remove(null)
            ..add(value);
        } else {
          _selectedTypes.remove(value);
          // 至少保留一项
          if (_selectedTypes.isEmpty) _selectedTypes.add(null);
        }
      }
    });
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
      AnswerFilterConfig(
        filterNoHomework: _filterNoHomework,
        filterCompleted: _filterCompleted,
        selectedTypes: _selectedTypes.toList(),
        selectedSubjects: _selectedSubjects.toList(),
      ),
    );
  }
}
