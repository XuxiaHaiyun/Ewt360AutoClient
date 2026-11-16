/// 上下文菜单组件: 桌面端右键 / 移动端长按弹出 PopupMenu,
/// 含 ContextMenuItem 定义 (图标/禁用/尾部组件/分割线) 与可选标题。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 桌面端右键 / 移动端长按 触发的上下文菜单包装组件
///
/// 用法:
/// ```dart
/// ContextMenuRegion(
///   menuBuilder: (context) => [
///     ContextMenuItem(label: '进度上报', icon: Icons.upload, onTap: () {}),
///   ],
///   child: MyCard(),
/// )
/// ```
class ContextMenuRegion extends StatefulWidget {
  final Widget child;
  final List<ContextMenuItem> Function(BuildContext context) menuBuilder;
  final String? title;

  const ContextMenuRegion({
    super.key,
    required this.child,
    required this.menuBuilder,
    this.title,
  });

  @override
  State<ContextMenuRegion> createState() => _ContextMenuRegionState();
}

class _ContextMenuRegionState extends State<ContextMenuRegion> {
  Offset _longPressPosition = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showMenu(details.globalPosition);
      },
      onLongPressStart: (details) {
        _longPressPosition = details.globalPosition;
      },
      onLongPress: () {
        _showMenu(_longPressPosition);
      },
      child: widget.child,
    );
  }

  void _showMenu(Offset position) {
    final items = widget.menuBuilder(context);
    if (items.isEmpty) return;

    HapticFeedback.mediumImpact();

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        MediaQuery.sizeOf(context).width - position.dx,
        MediaQuery.sizeOf(context).height - position.dy,
      ),
      items: [
        if (widget.title != null && widget.title!.isNotEmpty)
          PopupMenuItem<String>(
            enabled: false,
            height: 36,
            child: Text(
              widget.title!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (widget.title != null && widget.title!.isNotEmpty)
          const PopupMenuDivider(height: 8),
        for (final item in items)
          if (item.isDivider)
            const PopupMenuDivider(height: 8)
          else
            PopupMenuItem<String>(
              value: item.id,
              enabled: item.enabled,
              child: Row(
                children: [
                  if (item.icon != null) ...[
                    Icon(item.icon, size: 18,
                        color: item.enabled
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).disabledColor),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        color: item.enabled
                            ? null
                            : Theme.of(context).disabledColor,
                      ),
                    ),
                  ),
                  if (item.trailing != null) item.trailing!,
                ],
              ),
            ),
      ],
    ).then((value) {
      if (value == null) return;
      final item = items.where((i) => i.id == value).firstOrNull;
      item?.onTap?.call();
    });
  }
}

/// 上下文菜单项定义
class ContextMenuItem {
  final String id;
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool enabled;
  final Widget? trailing;
  final bool isDivider;

  const ContextMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.onTap,
    this.enabled = true,
    this.trailing,
  }) : isDivider = false;

  const ContextMenuItem.divider()
      : id = '__divider__',
        label = '',
        icon = null,
        onTap = null,
        enabled = false,
        trailing = null,
        isDivider = true;
}
