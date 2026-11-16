/// LaTeX 公式输入对话框：输入框 + 实时渲染预览 + 常用公式模板快捷插入。
/// showFormulaDialog 返回用户输入的 LaTeX 字符串，取消返回 null。
library;

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// 公式模板快捷插入
const List<(String, String)> _templates = [
  ('分式', r'\frac{a}{b}'),
  ('上下标', r'a_{i}^{2}'),
  ('根号', r'\sqrt{x}'),
  ('求和', r'\sum_{i=1}^{n} i'),
  ('积分', r'\int_{a}^{b} f(x)\,dx'),
  ('矩阵', r'\begin{matrix} a & b \\ c & d \end{matrix}'),
  ('极限', r'\lim_{x \to 0} \frac{\sin x}{x}'),
  ('向量', r'\vec{AB}'),
];

/// 公式输入对话框: 输入框 + 实时渲染预览 + 常用模板
///
/// [showFormulaDialog] 返回用户输入的 LaTeX 字符串 (取消返回 null)。
Future<String?> showFormulaDialog(BuildContext context, {String? initial}) async {
  return showDialog<String>(
    context: context,
    builder: (c) => _FormulaDialog(initial: initial),
  );
}

class _FormulaDialog extends StatefulWidget {
  final String? initial;
  const _FormulaDialog({this.initial});

  @override
  State<_FormulaDialog> createState() => _FormulaDialogState();
}

class _FormulaDialogState extends State<_FormulaDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial ?? r'\frac{a}{b}');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('插入公式 (LaTeX)'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: r'例如 \frac{a}{b}',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            // 模板快捷插入
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in _templates)
                  ActionChip(
                    label: Text(t.$1, style: const TextStyle(fontSize: 12)),
                    onPressed: () {
                      _ctrl.text = t.$2;
                      setState(() {});
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            const Text('实时预览', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(6),
              ),
              width: double.infinity,
              child: _Preview(_ctrl.text),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('插入'),
        ),
      ],
    );
  }
}

class _Preview extends StatelessWidget {
  final String latex;
  const _Preview(this.latex);

  @override
  Widget build(BuildContext context) {
    if (latex.trim().isEmpty) {
      return const Text('（空白公式）', style: TextStyle(color: Colors.grey));
    }
    try {
      return Math.tex(
        latex,
        onErrorFallback: (err) => Text(
          '公式渲染错误: $err',
          style: const TextStyle(color: Colors.red),
        ),
        mathStyle: MathStyle.display,
      );
    } catch (e) {
      return Text('公式渲染错误: $e', style: const TextStyle(color: Colors.red));
    }
  }
}
