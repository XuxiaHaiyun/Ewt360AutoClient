/// 周培优专用答案获取配置页（独立页面）：仅保留获取方案（direct/reportId/favorites）
/// 与展示内容字段选择，响应式宽屏双栏/窄屏单列布局。
library;

import 'package:flutter/material.dart';

import '../../../../core/layout/app_breakpoints.dart';
import '../../../answer/domain/entities/answer_config.dart';

/// 周培优专用答案获取配置页 (独立页面, 非弹窗)
///
/// 替代原 [WeekendAnswerConfigDialog]。与作业页 [AnswerConfigPage] 的区别:
/// 周培优任务无 homeworkId/taskId/subjectName/homeworkFinishStatus 等字段,
/// 作业场景的过滤选项 (无作业/已完成/课程类型/学科) 在周培优场景下均不适用,
/// 因此本页仅保留:
/// - 获取方案 (direct / reportId / favorites)
/// - 展示内容字段 (原题目/选项/答案/知识点/难度/解析)
///
/// 响应式布局 (提升空间利用率): 宽屏左右双栏 (方案 | 展示内容), 窄屏单列。
class WeekendAnswerConfigPage extends StatefulWidget {
  const WeekendAnswerConfigPage({super.key});

  /// 打开配置页面，返回方案与展示字段配置（取消返回 null）
  ///
  /// 页面 push 到 root navigator (与原 showDialog 的 useRootNavigator 行为
  /// 一致): 从 ShellRoute 内层页面打开时覆盖整个窗口, 不被底部导航遮挡。
  static Future<AnswerConfig?> show(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<AnswerConfig>(
      MaterialPageRoute(builder: (_) => const WeekendAnswerConfigPage()),
    );
  }

  @override
  State<WeekendAnswerConfigPage> createState() =>
      _WeekendAnswerConfigPageState();
}

class _WeekendAnswerConfigPageState extends State<WeekendAnswerConfigPage> {
  AnswerConfig _config = const AnswerConfig();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // ─── 方案选择 ───
    final methodSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            children: AnswerMethod.values
                .map((m) => RadioListTile<AnswerMethod>(
                      title: Text(m.label),
                      subtitle: Text(_methodDescription(m),
                          style: const TextStyle(fontSize: 12)),
                      value: m,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ))
                .toList(),
          ),
        ),
      ],
    );

    // ─── 展示内容字段 ───
    final displaySection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '展示内容'),
        Text(
          '选择需要获取和展示的题目字段',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        _buildFieldToggle('原题目', _config.showQuestionContent,
            (v) => setState(() => _config = _config.copyWith(showQuestionContent: v))),
        _buildFieldToggle('选项', _config.showOptions,
            (v) => setState(() => _config = _config.copyWith(showOptions: v))),
        _buildFieldToggle('答案', _config.showAnswer,
            (v) => setState(() => _config = _config.copyWith(showAnswer: v))),
        _buildFieldToggle('知识点', _config.showKnowledge,
            (v) => setState(() => _config = _config.copyWith(showKnowledge: v))),
        _buildFieldToggle('题目难度', _config.showDifficulty,
            (v) => setState(() => _config = _config.copyWith(showDifficulty: v))),
        _buildFieldToggle('解析', _config.showAnalysis,
            (v) => setState(() => _config = _config.copyWith(showAnalysis: v))),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回 (不保存)',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('获取试题答案'),
        actions: [
          FilledButton.icon(
            icon: const Icon(Icons.rocket_launch_outlined, size: 18),
            label: const Text('开始获取'),
            onPressed: () => Navigator.pop(context, _config),
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
                  methodSection,
                  const Divider(height: 24),
                  displaySection,
                ],
              ),
            );
          }
          // 宽屏双栏: 左 方案选择 | 右 展示内容
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
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: methodSection,
                  ),
                ),
              ),
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: displaySection,
                  ),
                ),
              ),
            ],
          );
        },
      ),
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

  Widget _buildFieldToggle(
      String label, bool value, ValueChanged<bool> onChanged) {
    return CheckboxListTile(
      title: Text(label),
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
    );
  }

  String _methodDescription(AnswerMethod m) {
    return switch (m) {
      AnswerMethod.auto => '由应用自动选择并切换最佳获取途径, 无需手动干预',
      AnswerMethod.direct => '仅获取已作答题目的答案, 速度最快',
      AnswerMethod.escalation => '适用范围最广的获取方式',
      AnswerMethod.favorites => '常规方式不可用时的备用获取途径',
      AnswerMethod.download => '获取含答案的教师版试卷 (PDF), 可直接查看',
    };
  }
}
