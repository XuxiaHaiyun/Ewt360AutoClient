/// 答案获取配置页（独立页面），一次完成方案选择、展示字段、过滤选项、完成操作及提交/图片上传配置。
/// 通过 AnswerConfigPage.show 打开，push 到根导航覆盖整个窗口；学科列表优先动态、失败回退本地。
library;

import 'package:flutter/material.dart';

import '../../../../core/layout/app_breakpoints.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../domain/entities/answer_config.dart';
import '../../domain/entities/image_upload_config.dart';
import '../../domain/entities/answer_filter_config.dart';
import '../../../editor/domain/entities/editor_config.dart';
import '../../../editor/presentation/editor_page.dart';
import '../widgets/generate_options_panel.dart';

/// 答案获取配置页 (独立页面, 非弹窗)
///
/// 替代原 [AnswerConfigDialog], 对应 Python: GUI 中答案获取方案选择 +
/// 内容字段配置 + 过滤配置。一次完成所有配置:
/// - 获取方案 (direct / reportId / favorites)
/// - 展示内容字段 (原题目/选项/答案/知识点/难度/解析)
/// - 过滤选项 (无作业/已完成课程)
/// - 课程类型/学科过滤
/// - 获取完成操作 (无操作/提交/导出 + 提交配置)
///
/// 响应式布局 (提升空间利用率):
/// - 宽屏 (expanded+): 左栏 方案+展示内容, 右栏 过滤+完成操作, 双栏并排
/// - 窄屏: 单列滚动
class AnswerConfigPage extends StatefulWidget {
  /// 动态学科列表 (优先使用, 为 null 时回退到本地列表 [kCourseSubjects])
  final List<String>? subjects;

  const AnswerConfigPage({super.key, this.subjects});

  /// 风控可见的获取方案 (feature key: `answer_method.<method.value>`)
  ///
  /// 配置缺失 = 放行; 显式 false = 隐藏该方案。返回空列表表示全部隐藏。
  static List<AnswerMethod> visibleMethods() => AnswerMethod.values
      .where(
        (m) => RiskControlGate.isFeatureEnabled('answer_method.${m.value}'),
      )
      .toList();

  /// 打开配置页面，返回用户配置（取消返回 null）
  ///
  /// [subjects] 动态学科列表 (来自 getStudentHomeworkDaySubjectStat),
  /// 为 null 时使用本地列表。优先动态加载, 失败回退本地列表。
  ///
  /// 页面 push 到 root navigator (与原 showDialog 的 useRootNavigator 行为
  /// 一致): 从 ShellRoute 内层页面 (作业/周培优) 打开时覆盖整个窗口,
  /// 不被侧栏/底部导航遮挡。
  static Future<AnswerConfigResult?> show(
    BuildContext context, {
    List<String>? subjects,
  }) {
    return Navigator.of(context, rootNavigator: true).push<AnswerConfigResult>(
      MaterialPageRoute(builder: (_) => AnswerConfigPage(subjects: subjects)),
    );
  }

  @override
  State<AnswerConfigPage> createState() => _AnswerConfigPageState();
}

class _AnswerConfigPageState extends State<AnswerConfigPage> {
  AnswerConfig _config = const AnswerConfig();

  /// 实际使用的学科列表 (动态优先, 失败回退本地)
  List<String> get _subjects => widget.subjects ?? kCourseSubjects;

  // ─── 过滤选项 (原 AnswerFilterDialog) ───
  bool _filterNoHomework = true;
  bool _filterCompleted = false;
  final Set<int?> _selectedTypes = {null};
  late final Set<String> _selectedSubjects;

  // ─── 获取完成操作 (提交配置) ───
  AnswerCompleteAction _completeAction = AnswerCompleteAction.none;

  /// 提交时的题型筛选 (空集合 = 全部题型)
  final Set<String> _submitTypes = {};

  /// 提交时图片上传类题型的方案配置 (null = 不上传图片)
  ImageUploadConfig? _imageUploadConfig;

  /// 图片上传方案选项 ('none'=不上传 / 'fixed'=固定图片 / 'generate'=根据答案生成)
  String get _imageUploadChoice {
    final cfg = _imageUploadConfig;
    if (cfg == null) return 'none';
    return switch (cfg.mode) {
      ImageUploadMode.fixed => 'fixed',
      ImageUploadMode.generate => 'generate',
      ImageUploadMode.custom => 'fixed',
      ImageUploadMode.editor => 'editor',
    };
  }

  @override
  void initState() {
    super.initState();
    _selectedSubjects = Set<String>.from(_subjects);
    // 默认方案被风控隐藏时, 规范化为第一个可见方案
    final visible = AnswerConfigPage.visibleMethods();
    if (visible.isNotEmpty && !visible.contains(_config.method)) {
      _config = _config.copyWith(method: visible.first);
    }
  }

  void _onConfirm() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (_selectedTypes.isEmpty) {
      messenger?.showSnackBar(const SnackBar(content: Text('请至少选择一个课程类型')));
      return;
    }
    if (_selectedSubjects.isEmpty) {
      messenger?.showSnackBar(const SnackBar(content: Text('请至少选择一个课程学科')));
      return;
    }

    Navigator.pop(
      context,
      AnswerConfigResult(
        config: _config.copyWith(
          completeAction: _completeAction,
          submitQuestionTypes: Set<String>.from(_submitTypes),
          imageUploadConfig: _imageUploadConfig,
        ),
        filterConfig: AnswerFilterConfig(
          filterNoHomework: _filterNoHomework,
          filterCompleted: _filterCompleted,
          selectedTypes: _selectedTypes.toList(),
          selectedSubjects: _selectedSubjects.toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 风控可见方案 (全部隐藏时收起整个方案选择区, 保持默认 auto)
    final visibleMethods = AnswerConfigPage.visibleMethods();
    final hasSubmitConfig = _completeAction != AnswerCompleteAction.none;

    // ─── 左栏: 方案 + 展示内容 ───
    final planSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (visibleMethods.isNotEmpty) ...[
          _sectionTitle(theme, '选择获取方案'),
          RadioGroup<AnswerMethod>(
            groupValue: _config.method,
            onChanged: (v) {
              if (v != null) {
                setState(() => _config = _config.copyWith(method: v));
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: visibleMethods
                  .map(
                    (m) => RadioListTile<AnswerMethod>(
                      title: Text(m.label),
                      subtitle: Text(
                        _methodDescription(m),
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: m,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  )
                  .toList(),
            ),
          ),
          const Divider(height: 24),
        ],
        _sectionTitle(theme, '展示内容'),
        Text(
          '选择需要获取和展示的题目字段',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        _buildFieldToggle(
          '原题目',
          _config.showQuestionContent,
          (v) => setState(
            () => _config = _config.copyWith(showQuestionContent: v),
          ),
        ),
        _buildFieldToggle(
          '选项',
          _config.showOptions,
          (v) => setState(() => _config = _config.copyWith(showOptions: v)),
        ),
        _buildFieldToggle(
          '答案',
          _config.showAnswer,
          (v) => setState(() => _config = _config.copyWith(showAnswer: v)),
        ),
        _buildFieldToggle(
          '知识点',
          _config.showKnowledge,
          (v) => setState(() => _config = _config.copyWith(showKnowledge: v)),
        ),
        _buildFieldToggle(
          '题目难度',
          _config.showDifficulty,
          (v) => setState(() => _config = _config.copyWith(showDifficulty: v)),
        ),
        _buildFieldToggle(
          '解析',
          _config.showAnalysis,
          (v) => setState(() => _config = _config.copyWith(showAnalysis: v)),
        ),
      ],
    );

    // ─── 右栏: 过滤选项 + 获取完成操作 (+提交配置) ───
    final filterSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '过滤选项'),
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
        const SizedBox(height: 12),

        // 课程类型
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

        // 课程学科
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
                if (_selectedSubjects.length == _subjects.length) {
                  _selectedSubjects.clear();
                } else {
                  _selectedSubjects
                    ..clear()
                    ..addAll(_subjects);
                }
              }),
              icon: Icon(
                _selectedSubjects.length == _subjects.length
                    ? Icons.deselect_outlined
                    : Icons.select_all_outlined,
                size: 18,
              ),
              label: Text(
                _selectedSubjects.length == _subjects.length
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
          children: _subjects.map((name) {
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
        const Divider(height: 24),

        // ─── 获取完成操作 ───
        _sectionTitle(theme, '获取完成操作'),
        Text(
          '获取答案完成后自动执行的动作',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        RadioGroup<AnswerCompleteAction>(
          groupValue: _completeAction,
          onChanged: (v) {
            if (v != null) setState(() => _completeAction = v);
          },
          child: Wrap(
            spacing: 4,
            runSpacing: -8,
            children: AnswerCompleteAction.values
                .map(
                  (a) => SizedBox(
                    width: 180,
                    child: RadioListTile<AnswerCompleteAction>(
                      title: Text(a.label, style: const TextStyle(fontSize: 13)),
                      value: a,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        if (hasSubmitConfig) ...[
          const Divider(height: 20),
          // ─── 提交配置 (提前显示) ───
          _sectionTitle(theme, '提交配置'),
          Text(
            '提交的题型 (不勾选 = 全部题型)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            children: kAnswerQuestionTypeOptions.map((t) {
              final checked = _submitTypes.contains(t);
              return FilterChip(
                label: Text(t),
                selected: checked,
                onSelected: (_) => _toggleSubmitType(t),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Text(
            '图片上传 (主观题)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          RadioGroup<String>(
            groupValue: _imageUploadChoice,
            onChanged: (v) => _setImageUploadChoice(v ?? 'none'),
            child: Wrap(
              spacing: 4,
              runSpacing: -8,
              children: const [
                _ImageUploadRadioTile('不上传图片', 'none'),
                _ImageUploadRadioTile('固定图片 (assets/images/onlyhead.png)', 'fixed'),
                _ImageUploadRadioTile('根据答案生成', 'generate'),
                _ImageUploadRadioTile('编辑器提交', 'editor'),
              ],
            ),
          ),
          if (_imageUploadConfig?.mode == ImageUploadMode.editor)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.edit, size: 16),
                label: const Text(
                  '打开编辑器',
                  style: TextStyle(fontSize: 13),
                ),
                onPressed: () async {
                  final result = await Navigator.of(context)
                      .push<EditorConfig>(
                        MaterialPageRoute(
                          builder: (_) => EditorPage(
                            initial:
                                _imageUploadConfig?.editor ??
                                const EditorConfig(),
                            onConfirm: (c) {},
                          ),
                        ),
                      );
                  if (result != null) {
                    setState(
                      () => _imageUploadConfig =
                          (_imageUploadConfig ??
                                  const ImageUploadConfig(
                                    mode: ImageUploadMode.editor,
                                  ))
                              .copyWith(editor: result),
                    );
                  }
                },
              ),
            ),
          // 根据答案生成: 完整选项面板 (显示内容/见解析开关/手写模拟配置)
          if (_imageUploadConfig?.mode == ImageUploadMode.generate)
            GenerateOptionsPanel(
              config: _imageUploadConfig!,
              onChanged: (c) => setState(() => _imageUploadConfig = c),
            ),
        ],
      ],
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回 (不保存)',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('获取试题答案'),
        actions: [
          FilledButton.icon(
            icon: const Icon(Icons.rocket_launch_outlined, size: 18),
            label: const Text('开始获取'),
            onPressed: _onConfirm,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= AppBreakpoints.expanded;
          if (!isWide) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  planSection,
                  const Divider(height: 24),
                  filterSection,
                ],
              ),
            );
          }
          // 宽屏双栏: 左 方案+展示内容 | 右 过滤+完成操作
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 380,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: theme.dividerColor),
                    ),
                  ),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: planSection,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: filterSection,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── 工具方法 ───

  Widget _sectionTitle(ThemeData theme, String text) {
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// 切换提交题型筛选 (空集合 = 全部题型)
  void _toggleSubmitType(String type) {
    setState(() {
      if (!_submitTypes.remove(type)) {
        _submitTypes.add(type);
      }
    });
  }

  /// 设置图片上传方案
  void _setImageUploadChoice(String choice) {
    setState(() {
      _imageUploadConfig = switch (choice) {
        'fixed' =>
          _imageUploadConfig?.mode == ImageUploadMode.fixed
              ? _imageUploadConfig
              : const ImageUploadConfig(mode: ImageUploadMode.fixed),
        'generate' =>
          _imageUploadConfig?.mode == ImageUploadMode.generate
              ? _imageUploadConfig
              : const ImageUploadConfig(mode: ImageUploadMode.generate),
        'editor' =>
          _imageUploadConfig?.mode == ImageUploadMode.editor
              ? _imageUploadConfig
              : const ImageUploadConfig(mode: ImageUploadMode.editor),
        _ => null,
      };
    });
  }

  /// 切换课程类型选择 (互斥: "全部" 与其他)
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

  Widget _buildFieldToggle(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return CheckboxListTile(
      title: Text(label),
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
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

  String _methodDescription(AnswerMethod m) {
    return switch (m) {
      AnswerMethod.auto =>
        '由应用自动选择并切换最佳获取途径, 无需手动干预',
      AnswerMethod.direct => '仅获取已作答题目的答案, 速度最快',
      AnswerMethod.escalation => '适用范围最广的获取方式',
      AnswerMethod.favorites => '常规方式不可用时的备用获取途径',
      AnswerMethod.download => '获取含答案的教师版试卷 (PDF), 可直接查看',
    };
  }
}

/// 图片上传方案的紧凑单选瓦片 (宽屏 Wrap 排列用)
class _ImageUploadRadioTile extends StatelessWidget {
  final String title;
  final String value;

  const _ImageUploadRadioTile(this.title, this.value);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: RadioListTile<String>(
        title: Text(title, style: const TextStyle(fontSize: 13)),
        value: value,
        dense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}
