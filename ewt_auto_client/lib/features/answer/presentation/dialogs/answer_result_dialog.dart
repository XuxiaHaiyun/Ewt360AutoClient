/// 答案展示弹窗，按课程分节展示获取到的试题答案并支持一键复制全部。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/question_info.dart';

/// 答案展示弹窗
///
/// 对应 Python: gui/dialogs/answer_dialog.py
class AnswerResultDialog extends StatelessWidget {
  final List<CourseAnswerResult> results;

  const AnswerResultDialog({super.key, required this.results});

  static Future<void> show(
    BuildContext context, {
    required List<CourseAnswerResult> results,
  }) {
    return showDialog(
      context: context,
      builder: (_) => AnswerResultDialog(results: results),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalQuestions =
        results.fold<int>(0, (sum, r) => sum + r.successCount);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.quiz_outlined,
                      color: theme.colorScheme.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '试题答案 (${results.length} 个课程, $totalQuestions 道题)',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  // 复制全部
                  IconButton(
                    icon: const Icon(Icons.copy_outlined, size: 20),
                    tooltip: '复制全部答案',
                    onPressed: () => _copyAll(context),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // 内容
            Flexible(
              child: results.isEmpty
                  ? const Center(child: Text('未获取到答案'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        return _CourseAnswerSection(
                          result: results[index],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyAll(BuildContext context) async {
    final buffer = StringBuffer();
    for (final result in results) {
      buffer.writeln('═══ ${result.courseTitle} ═══');
      buffer.writeln(
          '方案: ${result.method} | paperId: ${result.paperId} | ${result.successCount}/${result.totalCount} 题');
      buffer.writeln();
      for (final q in result.questions) {
        _writeQuestion(buffer, q, indent: '');
      }
      buffer.writeln();
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('答案已复制到剪贴板'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _writeQuestion(StringBuffer buffer, QuestionInfo q,
      {required String indent}) {
    final num = q.number.isNotEmpty ? '${q.number}. ' : '';
    buffer.writeln('$indent$num答案: ${_stripHtml(q.answer)}');
    if (q.knowledge.isNotEmpty) {
      buffer.writeln('$indent   知识点: ${q.knowledge}');
    }
    if (q.analysis.isNotEmpty) {
      buffer.writeln('$indent   解析: ${_stripHtml(q.analysis)}');
    }
    for (final child in q.childQuestions) {
      _writeQuestion(buffer, child, indent: '$indent   ');
    }
  }

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .trim();
  }
}

/// 单个课程的答案区块
class _CourseAnswerSection extends StatelessWidget {
  final CourseAnswerResult result;

  const _CourseAnswerSection({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 课程标题
            Row(
              children: [
                Expanded(
                  child: Text(
                    result.courseTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${result.successCount}/${result.totalCount}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '方案: ${result.method} | paperId: ${result.paperId}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 16),

            // 题目列表
            ...result.questions.map((q) => _QuestionTile(question: q)),
            if (result.questions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '未获取到题目答案',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单题展示
class _QuestionTile extends StatelessWidget {
  final QuestionInfo question;

  const _QuestionTile({required this.question});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasChildren = question.childQuestions.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 题号 + 答案
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (question.number.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(minWidth: 28),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    question.number,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 答案
                    _AnswerChip(answer: question.answer, theme: theme),
                    // 知识点
                    if (question.knowledge.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '知识点: ${question.knowledge}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    // 解析
                    if (question.analysis.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _HtmlText(
                        question.analysis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          // 子题
          if (hasChildren) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: question.childQuestions
                    .map((cq) => _QuestionTile(question: cq))
                    .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 答案标签
class _AnswerChip extends StatelessWidget {
  final String answer;
  final ThemeData theme;

  const _AnswerChip({required this.answer, required this.theme});

  @override
  Widget build(BuildContext context) {
    final isObjective = RegExp(r'^[A-Z](,\s*[A-Z])*$').hasMatch(answer);
    final hasHtml = !isObjective && answer.contains('<') && answer.contains('>');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isObjective
            ? Colors.green.withValues(alpha: 0.1)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isObjective
              ? Colors.green.withValues(alpha: 0.3)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: hasHtml
          ? _HtmlText(answer, style: theme.textTheme.bodyMedium)
          : Text(
              answer,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isObjective ? Colors.green.shade700 : null,
                fontWeight: isObjective ? FontWeight.w600 : null,
              ),
            ),
    );
  }
}

/// 轻量级 HTML 渲染组件
///
/// 支持常见内联标签: b/strong, i/em, u, sub, sup, br, p, div, img, span, font
class _HtmlText extends StatelessWidget {
  final String html;
  final TextStyle? style;

  const _HtmlText(this.html, {this.style});

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final spans = _parseHtml(html, baseStyle);
    if (spans.isEmpty) return const SizedBox.shrink();
    return RichText(text: TextSpan(children: spans));
  }

  static List<InlineSpan> _parseHtml(String html, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    final styleStack = <TextStyle>[baseStyle];

    for (final m in RegExp(r'<[^>]+>|[^<]+').allMatches(html)) {
      final token = m.group(0)!;
      if (!token.startsWith('<')) {
        final decoded = _decodeEntities(token);
        if (decoded.isNotEmpty) {
          spans.add(TextSpan(text: decoded, style: styleStack.last));
        }
        continue;
      }

      final lower = token.toLowerCase();
      final isClose = lower.startsWith('</');
      final tagName = RegExp(r'</?(\w+)').firstMatch(lower)?.group(1) ?? '';

      if (isClose) {
        if (styleStack.length > 1) styleStack.removeLast();
        continue;
      }

      final current = styleStack.last;
      switch (tagName) {
        case 'br':
          spans.add(TextSpan(text: '\n', style: current));
        case 'img':
          final src = RegExp(r'''src=["']?([^"'\s>]+)''')
              .firstMatch(token)
              ?.group(1);
          if (src != null && src.isNotEmpty) {
            spans.add(WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 100),
                child: Image.network(
                  src,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ));
          }
        case 'p':
        case 'div':
          if (spans.isNotEmpty) spans.add(TextSpan(text: '\n', style: current));
          styleStack.add(current);
        case 'b':
        case 'strong':
          styleStack.add(current.copyWith(fontWeight: FontWeight.bold));
        case 'i':
        case 'em':
          styleStack.add(current.copyWith(fontStyle: FontStyle.italic));
        case 'u':
          styleStack.add(current.copyWith(
            decoration: TextDecoration.combine([
              current.decoration ?? TextDecoration.none,
              TextDecoration.underline,
            ]),
          ));
        case 'sub':
        case 'sup':
          styleStack.add(current.copyWith(
            fontSize: (current.fontSize ?? 14) * 0.75,
          ));
        case 'span':
        case 'font':
          styleStack.add(_applyInlineStyle(current, token));
        default:
          styleStack.add(current);
      }
    }

    return spans;
  }

  /// 解析 span/font 标签的 style 属性
  static TextStyle _applyInlineStyle(TextStyle base, String tag) {
    var result = base;
    final styleMatch = RegExp(r'''style=["']([^"']*)["']''').firstMatch(tag);
    if (styleMatch != null) {
      for (final s in styleMatch.group(1)!.split(';')) {
        final idx = s.indexOf(':');
        if (idx < 0) continue;
        final prop = s.substring(0, idx).trim().toLowerCase();
        final val = s.substring(idx + 1).trim();
        switch (prop) {
          case 'color':
            final c = _parseColor(val);
            if (c != null) result = result.copyWith(color: c);
          case 'font-size':
            final sz = double.tryParse(
                RegExp(r'[\d.]+').firstMatch(val)?.group(0) ?? '');
            if (sz != null) result = result.copyWith(fontSize: sz);
          case 'font-weight':
            if (val == 'bold' || val == '700' || val == '800' || val == '900') {
              result = result.copyWith(fontWeight: FontWeight.bold);
            }
          case 'font-style':
            if (val == 'italic') {
              result = result.copyWith(fontStyle: FontStyle.italic);
            }
          case 'text-decoration':
            if (val.contains('underline')) {
              result = result.copyWith(
                decoration: TextDecoration.combine([
                  result.decoration ?? TextDecoration.none,
                  TextDecoration.underline,
                ]),
              );
            }
        }
      }
    }
    // font 标签的 color 属性
    final colorAttr = RegExp(r'''color=["']([^"']+)["']''').firstMatch(tag);
    if (colorAttr != null) {
      final c = _parseColor(colorAttr.group(1)!);
      if (c != null) result = result.copyWith(color: c);
    }
    return result;
  }

  static Color? _parseColor(String val) {
    val = val.trim();
    if (val.startsWith('#')) {
      final hex = val.substring(1);
      if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
      if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    }
    return _namedColors[val.toLowerCase()];
  }

  static String _decodeEntities(String text) {
    return text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  static const _namedColors = <String, Color>{
    'red': Color(0xFFFF0000),
    'green': Color(0xFF008000),
    'blue': Color(0xFF0000FF),
    'black': Color(0xFF000000),
    'white': Color(0xFFFFFFFF),
    'orange': Color(0xFFFFA500),
    'purple': Color(0xFF800080),
    'gray': Color(0xFF808080),
    'grey': Color(0xFF808080),
  };
}
