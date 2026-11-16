/// 更新日志页面：从 assets/changelog.json 动态读取版本记录，以时间轴形式展示。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 更新日志页面 — 时间轴展示
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  List<_ChangelogEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadChangelog();
  }

  Future<void> _loadChangelog() async {
    try {
      final raw = await rootBundle.loadString('assets/changelog.json');
      final list = jsonDecode(raw) as List;
      setState(() {
        _entries = list.map((e) => _ChangelogEntry.fromJson(e)).toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('更新日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(child: Text('暂无更新日志'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    final isFirst = index == 0;
                    final isLast = index == _entries.length - 1;
                    return _TimelineItem(
                      entry: entry,
                      isFirst: isFirst,
                      isLast: isLast,
                      theme: theme,
                    );
                  },
                ),
    );
  }
}

/// 时间轴单条记录
class _TimelineItem extends StatelessWidget {
  final _ChangelogEntry entry;
  final bool isFirst;
  final bool isLast;
  final ThemeData theme;

  const _TimelineItem({
    required this.entry,
    required this.isFirst,
    required this.isLast,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = theme.colorScheme;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─── 左侧时间轴 ───
          SizedBox(
            width: 32,
            child: Column(
              children: [
                // 上连线
                Container(
                  width: 2,
                  height: 6,
                  color: isFirst
                      ? Colors.transparent
                      : colorScheme.outlineVariant,
                ),
                // 圆点
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isFirst
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHighest,
                    border: Border.all(
                      color: isFirst
                          ? colorScheme.primary
                          : colorScheme.outline,
                      width: 2,
                    ),
                  ),
                ),
                // 下连线
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // ─── 右侧内容 ───
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 版本号 + 日期
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: isFirst
                              ? colorScheme.primaryContainer
                              : colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'v${entry.version}',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: isFirst
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        entry.date,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 标题
                  Text(
                    entry.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 变更列表
                  Card(
                    elevation: 0,
                    color: colorScheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          for (var i = 0; i < entry.changes.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            _ChangeRow(change: entry.changes[i], theme: theme),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条变更记录
class _ChangeRow extends StatelessWidget {
  final _ChangeItem change;
  final ThemeData theme;

  const _ChangeRow({required this.change, required this.theme});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (change.type) {
      'new' => (Icons.auto_awesome, theme.colorScheme.primary, '新增'),
      'improve' => (Icons.trending_up, theme.colorScheme.tertiary, '优化'),
      'fix' => (Icons.bug_report, theme.colorScheme.error, '修复'),
      _ => (Icons.circle, theme.colorScheme.onSurfaceVariant, '其他'),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            change.text,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

// ─── 数据模型 ───

class _ChangelogEntry {
  final String version;
  final String date;
  final String title;
  final List<_ChangeItem> changes;

  _ChangelogEntry({
    required this.version,
    required this.date,
    required this.title,
    required this.changes,
  });

  factory _ChangelogEntry.fromJson(Map<String, dynamic> json) {
    return _ChangelogEntry(
      version: json['version'] as String? ?? '',
      date: json['date'] as String? ?? '',
      title: json['title'] as String? ?? '',
      changes: (json['changes'] as List? ?? [])
          .map((c) => _ChangeItem.fromJson(c))
          .toList(),
    );
  }
}

class _ChangeItem {
  final String type;
  final String text;

  _ChangeItem({required this.type, required this.text});

  factory _ChangeItem.fromJson(Map<String, dynamic> json) {
    return _ChangeItem(
      type: json['type'] as String? ?? '',
      text: json['text'] as String? ?? '',
    );
  }
}
