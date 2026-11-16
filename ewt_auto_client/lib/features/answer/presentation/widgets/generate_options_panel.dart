/// "根据答案生成"模式的选项面板（单课程/批量提交弹窗共用），配置答案/解析显示内容、
/// "见解析"过滤及手写模拟开关（跳转手写模拟配置页），变更经 onChanged 回写 ImageUploadConfig。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/answer_filter_config.dart';
import '../../domain/entities/handwriting_config.dart';
import '../../domain/entities/image_upload_config.dart';
import '../providers/handwriting_config_provider.dart';

/// "根据答案生成"模式的选项面板 (单课程/批量提交弹窗共用)
///
/// 包含:
/// - 显示内容 (多选): 答案 / 解析
/// - 答案含"见解析"不展示开关
/// - 手写模拟开关 + 配置按钮 (跳转到手写模拟配置页 [HandwritingConfigPage])
///
/// [config] 为当前图片上传配置, 变更通过 [onChanged] 回调更新。
class GenerateOptionsPanel extends ConsumerWidget {
  final ImageUploadConfig config;
  final ValueChanged<ImageUploadConfig> onChanged;

  const GenerateOptionsPanel({
    super.key,
    required this.config,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text('显示内容 (多选)',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              )),
          CheckboxListTile(
            title: const Text('答案', style: TextStyle(fontSize: 14)),
            value: config.includeAnswer,
            onChanged: (v) {
              onChanged(config.copyWith(includeAnswer: v ?? false));
            },
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          CheckboxListTile(
            title: const Text('解析', style: TextStyle(fontSize: 14)),
            value: config.includeAnalysis,
            onChanged: (v) {
              onChanged(config.copyWith(includeAnalysis: v ?? false));
            },
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          // 答案含"见解析"不展示
          CheckboxListTile(
            title: const Text(
              '答案含"见解析"不展示',
              style: TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              '勾选后, 答案文本含"见解析"字样的题目, 生成的图片中不显示答案',
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
            value: config.hideAnswerContainsAnalysis,
            onChanged: config.includeAnswer
                ? (v) {
                    onChanged(config.copyWith(
                        hideAnswerContainsAnalysis: v ?? false));
                  }
                : null,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          // 仅特定学科显示解析
          CheckboxListTile(
            title: const Text(
              '仅特定学科显示解析',
              style: TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              '勾选后点击选择学科, 只有选中学科的题目在生成图片中显示解析',
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
            value: config.analysisSubjects.isNotEmpty,
            onChanged: config.includeAnalysis
                ? (v) {
                    if (v == true) {
                      _showSubjectPicker(context, ref, config);
                    } else {
                      onChanged(config.copyWith(analysisSubjects: {}));
                    }
                  }
                : null,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          // 已选学科展示 + 重新选择
          if (config.analysisSubjects.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已选: ${config.analysisSubjects.join('、')}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showSubjectPicker(context, ref, config),
                    child: const Text('重新选择',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          // 手写模拟
          CheckboxListTile(
            title: const Text(
              '手写模拟',
              style: TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              '以手写风格渲染答案/解析 (自定义字体/倾斜/涂改/纸张等)',
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
            value: config.handwriting != null,
            onChanged: (v) {
              if (v == true) {
                // 启用手写模拟: 沿用当前配置, 否则使用已持久化的默认配置
                onChanged(config.copyWith(
                    handwriting: config.handwriting ??
                        ref.read(handwritingConfigProvider)));
              } else {
                onChanged(config.copyWith(handwriting: null));
              }
            },
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          // 手写配置按钮
          if (config.handwriting != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.tune, size: 16),
                    label: Text(
                      '配置手写参数 (${config.handwriting!.font.label})',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () async {
                      // 跳转到独立手写模拟配置页 (非弹窗), 返回最新配置
                      final saved = await context.pushNamed(
                        'handwriting-config',
                        extra: config.handwriting,
                      );
                      if (saved is HandwritingConfig) {
                        onChanged(config.copyWith(handwriting: saved));
                      }
                    },
                  ),
                ],
              ),
            ),
          if (!config.includeAnswer && !config.includeAnalysis)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Text(
                '提示: 至少选择一项, 否则将回退到固定图片',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.orange[700],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 弹出学科多选弹窗 (仅特定学科显示解析)
  ///
  /// 取消/空选择保持原配置 (空集合 = 全部学科显示解析);
  /// 确定后通过 [onChanged] 更新 [ImageUploadConfig.analysisSubjects]。
  Future<void> _showSubjectPicker(
    BuildContext context,
    WidgetRef ref,
    ImageUploadConfig config,
  ) async {
    final subjects = kCourseSubjects;
    final selected = Set<String>.from(config.analysisSubjects);
    final confirmed = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('选择显示解析的学科 (${selected.length}/${subjects.length})'),
          content: SizedBox(
            width: 380,
            height: 320,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 2,
                children: subjects.map((s) {
                  final checked = selected.contains(s);
                  return FilterChip(
                    label: Text(s),
                    selected: checked,
                    onSelected: (_) => setState(() {
                      if (!selected.remove(s)) selected.add(s);
                    }),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setState(() {
                if (selected.length == subjects.length) {
                  selected.clear();
                } else {
                  selected
                    ..clear()
                    ..addAll(subjects);
                }
              }),
              child: Text(selected.length == subjects.length ? '清空' : '全选'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(selected),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == null) return; // 取消: 保持原配置
    onChanged(config.copyWith(analysisSubjects: Set<String>.from(confirmed)));
  }
}
