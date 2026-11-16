/// 提交配置弹窗与编辑器提交入口：选择要提交的题型、配置主观题图片上传方案（固定/生成/自定义/编辑器）。
/// buildEditorButtonSection 为单课程/批量提交弹窗共享的编辑器画布入口，编辑器返回后回写 ImageUploadConfig.editor。
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../domain/entities/image_upload_config.dart';
import '../../domain/entities/question_info.dart';
import '../../domain/services/answer_submit_service.dart';
import '../../../editor/domain/entities/editor_config.dart';
import '../../../editor/presentation/editor_page.dart';
import '../widgets/generate_options_panel.dart';

/// 编辑器提交: 打开集成画布编辑器 (共享于单课程/批量提交弹窗)
///
/// [config] 为当前图片上传配置, [onChanged] 在编辑器返回后回写 [ImageUploadConfig.editor]。
Widget buildEditorButtonSection(
  BuildContext context,
  ThemeData theme,
  ImageUploadConfig config,
  ValueChanged<ImageUploadConfig> onChanged,
) {
  return Padding(
    padding: const EdgeInsets.only(left: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.edit, size: 16),
          label: const Text('打开编辑器', style: TextStyle(fontSize: 13)),
          onPressed: () async {
            final result = await Navigator.of(context).push<EditorConfig>(
              MaterialPageRoute(
                builder: (_) => EditorPage(
                  initial: config.editor ?? const EditorConfig(),
                  onConfirm: (c) {},
                ),
              ),
            );
            if (result != null) {
              onChanged(config.copyWith(editor: result));
            }
          },
        ),
        if (config.editor != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '已配置编辑器: ${config.editor!.components.length} 个组件',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );
}

/// 提交配置弹窗
///
/// 选择要提交的题型, 确认后调用 [onConfirm] 回调.
/// 对齐 Web answer-pc 的 "提交试卷" 确认弹窗 (visibleCir),
/// 但增加了题型筛选功能, 让用户可以选择只提交部分题型.
///
/// 额外支持图片上传类题型的上传方案配置:
/// - 固定图片 (默认 assets/images/onlyhead.png)
/// - 根据答案生成 (可选显示答案/解析, 生成的图片不含"答案"/"解析"字样)
class SubmitConfigDialog extends StatefulWidget {
  /// 课程答案结果
  final CourseAnswerResult result;

  /// 提交类型
  final SubmitType type;

  /// 确认提交回调
  ///
  /// [selectedQuestions] 为选中的题目列表 (已按题型过滤)
  /// [imageUploadConfig] 为图片上传配置 (可能为 null 表示不上传图片)
  /// [reportId] 为 (可能手动修改后的) 有效 reportId
  final Future<void> Function(
    List<QuestionInfo> selectedQuestions,
    ImageUploadConfig? imageUploadConfig,
    String reportId,
  ) onConfirm;

  /// 初始图片上传配置 (null 表示使用默认值)
  final ImageUploadConfig? initialImageUploadConfig;

  const SubmitConfigDialog({
    super.key,
    required this.result,
    required this.type,
    required this.onConfirm,
    this.initialImageUploadConfig,
  });

  @override
  State<SubmitConfigDialog> createState() => _SubmitConfigDialogState();
}

class _SubmitConfigDialogState extends State<SubmitConfigDialog> {
  /// 题型 → 是否选中
  late final Map<String, bool> _typeSelection;

  /// 题型 → 题目列表
  late final Map<String, List<QuestionInfo>> _typeQuestions;

  /// 图片上传配置
  late ImageUploadConfig _imageUploadConfig;

  /// 是否启用图片上传
  late bool _imageUploadEnabled;

  bool _submitting = false;

  /// 手动填写的 reportId (缺失时用户可自行填写)
  late final TextEditingController _reportIdController;

  /// 是否正在手动填写 reportId (缺失时点击行进入)
  bool _editingReportId = false;

  /// 当前生效的 reportId (自动 + 手动)
  String get _effectiveReportId => _reportIdController.text.trim();

  @override
  void initState() {
    super.initState();
    _typeQuestions = _groupByType(widget.result.questions);
    // 默认全选
    _typeSelection = {
      for (final key in _typeQuestions.keys) key: true,
    };
    _imageUploadConfig = widget.initialImageUploadConfig ?? const ImageUploadConfig();
    _imageUploadEnabled = true;
    _reportIdController = TextEditingController(text: widget.result.reportId);
  }

  @override
  void dispose() {
    _reportIdController.dispose();
    super.dispose();
  }

  /// 按题型分组题目
  ///
  /// 题型取自 [QuestionInfo.questionType], 为空时归为 "未分类".
  /// 分组题 (有 childQuestions) 按父题题型归类.
  Map<String, List<QuestionInfo>> _groupByType(List<QuestionInfo> questions) {
    final result = <String, List<QuestionInfo>>{};
    for (final q in questions) {
      final type = q.questionType.isNotEmpty ? q.questionType : '未分类';
      result.putIfAbsent(type, () => []).add(q);
    }
    // 按题量降序排列
    final sorted = result.keys.toList()
      ..sort((a, b) => result[b]!.length.compareTo(result[a]!.length));
    return {for (final k in sorted) k: result[k]!};
  }

  /// 获取选中的题目列表
  List<QuestionInfo> get _selectedQuestions {
    final list = <QuestionInfo>[];
    for (final entry in _typeSelection.entries) {
      if (entry.value) {
        list.addAll(_typeQuestions[entry.key] ?? []);
      }
    }
    return list;
  }

  /// 统计选中题目中有 id 的数量 (可提交数量)
  int get _submittableCount {
    int count = 0;
    for (final q in _selectedQuestions) {
      if (q.childQuestions.isNotEmpty) {
        for (final child in q.childQuestions) {
          if (child.id.isNotEmpty) count++;
        }
      } else if (q.id.isNotEmpty) {
        count++;
      }
    }
    return count;
  }

  /// 统计选中题目中的主观题数量 (需要上传图片的题目)
  int get _subjectiveCount {
    int count = 0;
    for (final q in _selectedQuestions) {
      if (q.childQuestions.isNotEmpty) {
        for (final child in q.childQuestions) {
          if (child.id.isNotEmpty && child.subjective) count++;
        }
      } else if (q.id.isNotEmpty && q.subjective) {
        count++;
      }
    }
    return count;
  }

  Future<void> _onConfirm() async {
    final selected = _selectedQuestions;
    if (selected.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('请至少选择一个题型')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      await widget.onConfirm(
        selected,
        _imageUploadEnabled ? _imageUploadConfig : null,
        _effectiveReportId,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final typeLabel = widget.type == SubmitType.trace ? '提交做题痕迹' : '提交答题结果';
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(typeLabel),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 课程信息
              _InfoRow(label: '课程', value: result.courseTitle),
              _InfoRow(label: 'paperId', value: result.paperId),
              // reportId: 正常时只读展示, 缺失时显示 "(缺少，点击手动填写)",
              // 点击后切换为输入框手动补填
              if (_editingReportId)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 6),
                  child: TextField(
                    controller: _reportIdController,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'reportId',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      hintText: '请输入 reportId',
                      errorText: _effectiveReportId.isEmpty
                          ? '缺少reportId，无法提交'
                          : null,
                      suffixIcon: _effectiveReportId.isNotEmpty
                          ? const Icon(Icons.check_circle,
                              color: Colors.green, size: 18)
                          : null,
                    ),
                  ),
                )
              else
                InkWell(
                  onTap: _effectiveReportId.isEmpty
                      ? () => setState(() => _editingReportId = true)
                      : null,
                  child: _InfoRow(
                    label: 'reportId',
                    value: _effectiveReportId.isNotEmpty
                        ? _effectiveReportId
                        : '(缺少，点击手动填写)',
                    valueColor: _effectiveReportId.isNotEmpty
                        ? null
                        : Colors.red,
                  ),
                ),
              _InfoRow(
                label: 'bizCode',
                value: result.bizCode,
              ),
              if (result.homeworkId.isNotEmpty)
                _InfoRow(label: 'homeworkId', value: result.homeworkId),

              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // 题型选择
              Row(
                children: [
                  const Text('选择题型',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_typeSelection.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        final allSelected =
                            _typeSelection.values.every((v) => v);
                        setState(() {
                          for (final key in _typeSelection.keys) {
                            _typeSelection[key] = !allSelected;
                          }
                        });
                      },
                      child: Text(
                        _typeSelection.values.every((v) => v) ? '全不选' : '全选',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              ..._typeQuestions.entries.map((entry) {
                final type = entry.key;
                final questions = entry.value;
                final selected = _typeSelection[type] ?? false;
                final withIdCount = questions.fold<int>(0, (sum, q) {
                  if (q.childQuestions.isNotEmpty) {
                    return sum +
                        q.childQuestions.where((c) => c.id.isNotEmpty).length;
                  }
                  return sum + (q.id.isNotEmpty ? 1 : 0);
                });

                return CheckboxListTile(
                  value: selected,
                  onChanged: _effectiveReportId.isNotEmpty
                      ? (v) {
                          setState(() {
                            _typeSelection[type] = v ?? false;
                          });
                        }
                      : null,
                  title: Text(type),
                  subtitle: Text(
                    '$withIdCount/${questions.length} 题可提交'
                    '${withIdCount < questions.length ? " (部分缺少 id)" : ""}',
                    style: TextStyle(
                      fontSize: 12,
                      color: withIdCount < questions.length
                          ? Colors.orange[700]
                          : Colors.grey,
                    ),
                  ),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                );
              }),

              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // 图片上传方案配置
              _buildImageUploadSection(theme, _effectiveReportId.isNotEmpty),

              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // 提交概要
              Text(
                '将提交 $_submittableCount 道题的${widget.type == SubmitType.trace ? '做题痕迹' : '答题结果'}'
                '${_imageUploadEnabled && _subjectiveCount > 0 ? " (含 $_subjectiveCount 道主观题图片)" : ""}',
                style: TextStyle(
                  fontSize: 13,
                  color: _submittableCount > 0 ? Colors.blue : Colors.red,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              (_submitting || _effectiveReportId.isEmpty || _submittableCount == 0)
                  ? null
                  : _onConfirm,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.type == SubmitType.trace ? '保存' : '交卷'),
        ),
      ],
    );
  }

  /// 图片上传方案配置区块
  Widget _buildImageUploadSection(ThemeData theme, bool hasReportId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('图片上传方案',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Switch(
              value: _imageUploadEnabled,
              onChanged: hasReportId
                  ? (v) => setState(() => _imageUploadEnabled = v)
                  : null,
            ),
          ],
        ),
        if (_imageUploadEnabled) ...[
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              '为主观题 ($_subjectiveCount 道) 上传图片作答',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          // 上传模式选择
          RadioGroup<ImageUploadMode>(
            groupValue: _imageUploadConfig.mode,
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _imageUploadConfig = _imageUploadConfig.copyWith(mode: v);
                });
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<ImageUploadMode>(
                  title: const Text('固定图片'),
                  subtitle: const Text(
                    '使用内置 assets/images/onlyhead.png',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.fixed,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
                RadioListTile<ImageUploadMode>(
                  title: const Text('根据答案生成'),
                  subtitle: const Text(
                    '渲染答案/解析内容为图片 (不含"答案"/"解析"字样)',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.generate,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
                RadioListTile<ImageUploadMode>(
                  title: const Text('自定义图片'),
                  subtitle: const Text(
                    '从本机选择图片 (可多张), 支持全部相同/手动分配',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.custom,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
                RadioListTile<ImageUploadMode>(
                  title: const Text('编辑器提交'),
                  subtitle: const Text(
                    '画布集成编辑器: 文本/图片/公式/涂鸦组件可移动缩放旋转',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.editor,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
              ],
            ),
          ),
          // 根据答案生成的选项 (显示内容/见解析开关/手写模拟)
          if (_imageUploadConfig.mode == ImageUploadMode.generate)
            GenerateOptionsPanel(
              config: _imageUploadConfig,
              onChanged: (c) => setState(() => _imageUploadConfig = c),
            ),
          // 自定义图片: 从本机选择图片 (可多张), 按主观题循环分配
          if (_imageUploadConfig.mode == ImageUploadMode.custom)
            _buildCustomImagePicker(theme),
          // 编辑器提交: 打开集成画布编辑器
          if (_imageUploadConfig.mode == ImageUploadMode.editor)
            buildEditorButtonSection(
              context,
              theme,
              _imageUploadConfig,
              (c) => setState(() => _imageUploadConfig = c),
            ),
        ],
      ],
    );
  }

  /// 自定义图片选择器 (mode=custom 时显示)
  ///
  /// 包含分配策略选择 (每题一张循环 / 全部相同 / 手动分配):
  /// - perQuestion / allShared: 用 [_pickCustomImages] 选择图片池
  /// - manual: 用 [_pickManualImages] 为每道主观题单独选图 (可多张)
  Widget _buildCustomImagePicker(ThemeData theme) {
    final assignment = _imageUploadConfig.customAssignment;
    final count = _imageUploadConfig.customImageCount;
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text('分配方式',
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          SegmentedButton<CustomImageAssignment>(
            segments: const [
              ButtonSegment(
                  value: CustomImageAssignment.allShared,
                  label: Text('全部相同', style: TextStyle(fontSize: 11))),
              ButtonSegment(
                  value: CustomImageAssignment.manual,
                  label: Text('手动分配', style: TextStyle(fontSize: 11))),
            ],
            selected: {assignment},
            onSelectionChanged: (s) {
              if (s.isNotEmpty) {
                setState(() => _imageUploadConfig = _imageUploadConfig
                    .copyWith(customAssignment: s.first));
              }
            },
          ),
          const SizedBox(height: 8),
          if (assignment == CustomImageAssignment.manual)
            _buildManualAssignment(theme)
          else
            _buildPoolPicker(theme, count),
        ],
      ),
    );
  }

  /// 图片池选择器 (perQuestion / allShared 用)
  Widget _buildPoolPicker(ThemeData theme, int count) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.image_outlined, size: 18),
              label: Text(count > 0 ? '已选 $count 张, 重新选择' : '选择图片'),
              onPressed: _pickCustomImages,
            ),
            if (count > 0) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() {
                  _imageUploadConfig = _imageUploadConfig.copyWith(
                    customImageBytes: const [],
                    customImageNames: const [],
                  );
                }),
                child: const Text('清空'),
              ),
            ],
          ],
        ),
        if (count > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _imageUploadConfig.customImageNames.join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _imageUploadConfig.customAssignment ==
                      CustomImageAssignment.allShared
                  ? '未选择图片 (每题将用全部选中图片)'
                  : '未选择图片 (主观题将不上传图片)',
              style: TextStyle(fontSize: 11, color: Colors.orange[700]),
            ),
          ),
      ],
    );
  }

  /// 手动分配: 列出每道主观题, 逐题选择图片 (可多张)
  Widget _buildManualAssignment(ThemeData theme) {
    final subjective = _subjectiveQuestions;
    if (subjective.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('无可上传的主观题 (需题目含 id 且为 subjective)',
            style: TextStyle(fontSize: 11, color: Colors.orange[700])),
      );
    }
    final configured = _imageUploadConfig.manualImageBytes.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('共 ${subjective.length} 道主观题, 已配置 $configured 题',
            style: TextStyle(
                fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        ...subjective.map((q) => _buildManualRow(theme, q)),
      ],
    );
  }

  /// 手动分配单行 (题号 + 选图按钮 + 已选数量/文件名)
  Widget _buildManualRow(ThemeData theme, QuestionInfo q) {
    final label = q.questionNoShow.isNotEmpty
        ? q.questionNoShow
        : (q.number.isNotEmpty ? q.number : q.id);
    final imgs = _imageUploadConfig.manualImageBytes[q.id] ?? const [];
    final names = _imageUploadConfig.manualImageNames[q.id] ?? const [];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text('题 $label',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.image_outlined, size: 16),
            label: Text(imgs.isEmpty ? '选图' : '${imgs.length} 张'),
            onPressed: () => _pickManualImages(q.id),
          ),
          if (imgs.isNotEmpty) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => setState(() {
                final bytes = Map<String, List<Uint8List>>.from(
                    _imageUploadConfig.manualImageBytes);
                final namesMap = Map<String, List<String>>.from(
                    _imageUploadConfig.manualImageNames);
                bytes.remove(q.id);
                namesMap.remove(q.id);
                _imageUploadConfig = _imageUploadConfig.copyWith(
                  manualImageBytes: bytes,
                  manualImageNames: namesMap,
                );
              }),
              child: const Text('清空'),
            ),
            Flexible(
              child: Text(
                names.join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 收集已选题目中的主观题叶子 (有 id 且 subjective), 用于手动分配
  List<QuestionInfo> get _subjectiveQuestions {
    final list = <QuestionInfo>[];
    for (final q in _selectedQuestions) {
      if (q.childQuestions.isNotEmpty) {
        for (final c in q.childQuestions) {
          if (c.id.isNotEmpty && c.subjective) list.add(c);
        }
      } else if (q.id.isNotEmpty && q.subjective) {
        list.add(q);
      }
    }
    return list;
  }

  /// 调用 file_picker 选择多张图片 (图片池, perQuestion/allShared 用)
  Future<void> _pickCustomImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = <Uint8List>[];
    final names = <String>[];
    for (final f in result.files) {
      final b = f.bytes;
      if (b != null && b.isNotEmpty) {
        bytes.add(b);
        names.add(f.name.isNotEmpty ? f.name : 'custom_${names.length}.png');
      }
    }
    if (bytes.isEmpty) return;
    setState(() {
      _imageUploadConfig = _imageUploadConfig.copyWith(
        customImageBytes: bytes,
        customImageNames: names,
      );
    });
  }

  /// 为指定主观题 (questionId) 选择多张图片 (手动分配用)
  Future<void> _pickManualImages(String questionId) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = <Uint8List>[];
    final names = <String>[];
    for (final f in result.files) {
      final b = f.bytes;
      if (b != null && b.isNotEmpty) {
        bytes.add(b);
        names.add(f.name.isNotEmpty ? f.name : 'q${names.length}.png');
      }
    }
    if (bytes.isEmpty) return;
    setState(() {
      final bytesMap = Map<String, List<Uint8List>>.from(
          _imageUploadConfig.manualImageBytes);
      final namesMap = Map<String, List<String>>.from(
          _imageUploadConfig.manualImageNames);
      bytesMap[questionId] = bytes;
      namesMap[questionId] = names;
      _imageUploadConfig = _imageUploadConfig.copyWith(
        manualImageBytes: bytesMap,
        manualImageNames: namesMap,
      );
    });
  }
}

/// 信息行 (label: value)
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 批量提交配置弹窗
///
/// 用于在答案展示页 (answer_result_page) 批量提交全部课程的
/// 做题痕迹 / 作答结果:
/// - 展示课程清单与题量摘要 (含 reportId 缺失提示)
/// - 统一配置图片上传方案 (应用到所有课程的主观题)
/// - 每个课程提交其全部题目 (不做题型过滤)
///
/// 与 [SubmitConfigDialog] 的区别:
/// - [SubmitConfigDialog] 面向单课程, 可按题型筛选;
/// - 本弹窗面向多课程, 不做题型筛选, 仅统一图片上传方案。
class BatchSubmitConfigDialog extends StatefulWidget {
  /// 全部课程答案结果
  final List<CourseAnswerResult> results;

  /// 提交类型
  final SubmitType type;

  /// 初始图片上传配置 (null 表示使用默认值)
  final ImageUploadConfig? initialImageUploadConfig;

  /// 确认提交回调
  ///
  /// [imageUploadConfig] 为最终生效的图片上传配置
  /// [imageUploadEnabled] 为是否启用图片上传
  final Future<void> Function(
    ImageUploadConfig? imageUploadConfig,
    bool imageUploadEnabled,
  ) onConfirm;

  const BatchSubmitConfigDialog({
    super.key,
    required this.results,
    required this.type,
    this.initialImageUploadConfig,
    required this.onConfirm,
  });

  @override
  State<BatchSubmitConfigDialog> createState() =>
      _BatchSubmitConfigDialogState();
}

class _BatchSubmitConfigDialogState extends State<BatchSubmitConfigDialog> {
  late ImageUploadConfig _imageUploadConfig;
  late bool _imageUploadEnabled;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _imageUploadConfig =
        widget.initialImageUploadConfig ?? const ImageUploadConfig();
    _imageUploadEnabled = true;
  }

  int get _totalQuestions =>
      widget.results.fold<int>(0, (s, r) => s + r.successCount);

  /// 含 reportId (可提交) 的课程数
  int get _submittableCourses =>
      widget.results.where((r) => r.reportId.isNotEmpty).length;

  Future<void> _onConfirm() async {
    setState(() => _submitting = true);
    try {
      await widget.onConfirm(
        _imageUploadConfig,
        _imageUploadEnabled,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final typeLabel =
        widget.type == SubmitType.trace ? '做题痕迹' : '作答结果';
    final theme = Theme.of(context);
    final missingReport = _submittableCourses < widget.results.length;

    return AlertDialog(
      title: Text('批量提交$typeLabel'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 摘要
              _SummaryRow(label: '课程数', value: '${widget.results.length}'),
              _SummaryRow(label: '题目总数', value: '$_totalQuestions'),
              _SummaryRow(
                label: '可提交',
                value: '$_submittableCourses 个课程 (含 reportId)',
                valueColor: missingReport ? Colors.orange : Colors.green,
              ),
              if (missingReport) ...[
                const SizedBox(height: 6),
                Text(
                  '${widget.results.length - _submittableCourses} 个课程缺少 reportId, 将自动跳过',
                  style: TextStyle(fontSize: 12, color: Colors.orange[700]),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '将提交全部课程的所有题目, 不做题型过滤',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),

              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // 图片上传方案 (统一应用到全部课程)
              _buildImageUploadSection(theme),

              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // 课程清单 (截断展示)
              Text('课程清单', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ...widget.results.take(8).map((r) => _CourseRow(result: r)),
              if (widget.results.length > 8)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '... 及其他 ${widget.results.length - 8} 个课程',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_submitting || _submittableCourses == 0)
              ? null
              : _onConfirm,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('开始提交'),
        ),
      ],
    );
  }

  /// 图片上传方案配置区块 (与 SubmitConfigDialog 保持一致的交互)
  Widget _buildImageUploadSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('图片上传方案',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Switch(
              value: _imageUploadEnabled,
              onChanged: (v) => setState(() => _imageUploadEnabled = v),
            ),
          ],
        ),
        if (_imageUploadEnabled) ...[
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              '为主观题统一上传图片作答 (应用到全部课程)',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          RadioGroup<ImageUploadMode>(
            groupValue: _imageUploadConfig.mode,
            onChanged: (v) {
              if (v != null) {
                setState(() => _imageUploadConfig =
                    _imageUploadConfig.copyWith(mode: v));
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<ImageUploadMode>(
                  title: const Text('固定图片'),
                  subtitle: const Text(
                    '使用内置 assets/images/onlyhead.png',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.fixed,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
                RadioListTile<ImageUploadMode>(
                  title: const Text('根据答案生成'),
                  subtitle: const Text(
                    '渲染答案/解析内容为图片 (不含"答案"/"解析"字样)',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.generate,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
                RadioListTile<ImageUploadMode>(
                  title: const Text('自定义图片'),
                  subtitle: const Text(
                    '从本机选择图片 (可多张), 支持全部相同/手动分配',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.custom,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
                RadioListTile<ImageUploadMode>(
                  title: const Text('编辑器提交'),
                  subtitle: const Text(
                    '画布集成编辑器: 文本/图片/公式/涂鸦组件可移动缩放旋转',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: ImageUploadMode.editor,
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
                ),
              ],
            ),
          ),
          if (_imageUploadConfig.mode == ImageUploadMode.generate)
            GenerateOptionsPanel(
              config: _imageUploadConfig,
              onChanged: (c) =>
                  setState(() => _imageUploadConfig = c),
            ),
          // 自定义图片: 从本机选择图片 (可多张), 按主观题循环分配 (应用到全部课程)
          if (_imageUploadConfig.mode == ImageUploadMode.custom)
            _buildCustomImagePicker(theme),
          // 编辑器提交: 打开集成画布编辑器
          if (_imageUploadConfig.mode == ImageUploadMode.editor)
            buildEditorButtonSection(
              context,
              theme,
              _imageUploadConfig,
              (c) => setState(() => _imageUploadConfig = c),
            ),
        ],
      ],
    );
  }

  /// 自定义图片选择器 (mode=custom 时显示)
  Widget _buildCustomImagePicker(ThemeData theme) {
    final count = _imageUploadConfig.customImageCount;
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(count > 0 ? '已选 $count 张, 重新选择' : '选择图片'),
                onPressed: _pickCustomImages,
              ),
              if (count > 0) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _imageUploadConfig = _imageUploadConfig.copyWith(
                      customImageBytes: const [],
                      customImageNames: const [],
                    );
                  }),
                  child: const Text('清空'),
                ),
              ],
            ],
          ),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _imageUploadConfig.customImageNames.join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '未选择图片 (主观题将不上传图片)',
                style: TextStyle(fontSize: 11, color: Colors.orange[700]),
              ),
            ),
        ],
      ),
    );
  }

  /// 调用 file_picker 选择多张图片 (withData 直接读取字节) 并存入配置
  Future<void> _pickCustomImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = <Uint8List>[];
    final names = <String>[];
    for (final f in result.files) {
      final b = f.bytes;
      if (b != null && b.isNotEmpty) {
        bytes.add(b);
        names.add(f.name.isNotEmpty ? f.name : 'custom_${names.length}.png');
      }
    }
    if (bytes.isEmpty) return;
    setState(() {
      _imageUploadConfig = _imageUploadConfig.copyWith(
        customImageBytes: bytes,
        customImageNames: names,
      );
    });
  }
}

/// 摘要行 (label: value)
class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// 课程清单行 (标题 + 题量 + reportId 状态)
class _CourseRow extends StatelessWidget {
  final CourseAnswerResult result;
  const _CourseRow({required this.result});

  @override
  Widget build(BuildContext context) {
    final hasReport = result.reportId.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Icon(
            hasReport ? Icons.check_circle : Icons.warning_amber,
            size: 14,
            color: hasReport ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              result.courseTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Text(
            '${result.successCount}题',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
