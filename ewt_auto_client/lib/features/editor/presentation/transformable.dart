/// 可变换组件容器，提供移动/等比缩放/旋转手势交互，手势位移按画布缩放比例换算回逻辑坐标。
/// onGestureStart 供外部做撤销快照，onDoubleTap 用于双击编辑组件内容。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'canvas_background.dart';
import '../domain/entities/editor_config.dart';

/// 可变换组件：在画布上为组件提供 移动 / 缩放 / 旋转 交互
///
/// - 拖动组件主体 → 移动
/// - 右下角手柄 → 等比缩放
/// - 顶部手柄 → 旋转
/// [viewScale] 为画布当前缩放 (画布逻辑 px → 视口 px)；手势位移会按此换算回逻辑坐标。
class TransformableComponent extends StatefulWidget {
  final EditorComponent component;
  final double viewScale;
  final bool selected;
  final GlobalKey canvasKey;
  final void Function(EditorComponent) onChanged;
  final void Function() onSelect;

  /// 手势开始 (移动/缩放/旋转任一) 时回调, 供外部做撤销快照
  final void Function()? onGestureStart;
  final void Function(EditorComponent)? onDoubleTap;

  const TransformableComponent({
    super.key,
    required this.component,
    required this.viewScale,
    required this.selected,
    required this.canvasKey,
    required this.onChanged,
    required this.onSelect,
    this.onGestureStart,
    this.onDoubleTap,
  });

  @override
  State<TransformableComponent> createState() => _TransformableComponentState();
}

class _TransformableComponentState extends State<TransformableComponent> {
  /// 手势中的临时变换状态
  double? _dragScale;
  double? _dragRotation;
  double? _dragX;
  double? _dragY;

  EditorComponent get _effective {
    final c = widget.component;
    return c.copyWith(
      x: _dragX ?? c.x,
      y: _dragY ?? c.y,
      scale: _dragScale ?? c.scale,
      rotation: _dragRotation ?? c.rotation,
    );
  }

  /// 全局坐标 → 画布显示坐标 (画布左上角为原点, 已含 viewScale)
  ///
  /// 手柄的旋转/缩放计算都基于画布显示坐标系, 不能直接用 globalPosition。
  Offset _toCanvasDisplay(Offset global) {
    final box = widget.canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return global;
    return box.globalToLocal(global);
  }

  @override
  Widget build(BuildContext context) {
    final c = _effective;
    final vs = widget.viewScale;

    // 组件本体按画布逻辑坐标渲染 (与导出服务 buildCanvas 完全一致),
    // InteractiveViewer 的缩放负责显示放大, 这里不再乘 viewScale,
    // 保证预览比例 == 导出比例。
    final boxW = c.width * c.scale;
    final boxH = c.height * c.scale;

    // 手柄尺寸换算为画布坐标, 使其在屏幕上恒定约 36px
    final handle = 36.0 / vs;
    final rotateOffset = 28.0 / vs;

    final child = buildComponentWidget(c.copyWith(
      width: c.width * c.scale,
      height: c.height * c.scale,
      textFontSize: (c.textFontSize ?? 24) * c.scale,
      formulaFontSize: (c.formulaFontSize ?? 24) * c.scale,
    ));

    return Positioned(
      left: c.x,
      top: c.y,
      width: boxW,
      height: boxH,
      child: Transform.rotate(
        angle: c.rotation * math.pi / 180,
        // Listener 在指针按下瞬间选中, 不经手势竞技场 (GestureDetector 的
        // onTap 会因 onDoubleTap 的存在延迟 ~300ms 才触发)
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => widget.onSelect(),
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            widget.onGestureStart?.call();
            widget.onSelect();
          },
          onDoubleTap: widget.onDoubleTap == null
              ? null
              : () => widget.onDoubleTap!(widget.component),
          onPanUpdate: (e) {
            setState(() {
              _dragX = (c.x + e.delta.dx / vs);
              _dragY = (c.y + e.delta.dy / vs);
            });
            widget.onChanged(_effective);
          },
          onPanEnd: (_) {
            widget.onChanged(_effective);
            _dragX = _dragY = null;
            if (mounted) setState(() {});
          },
          child: Stack(
            children: [
              child,
              if (widget.selected)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.blue, width: 1.5 / vs),
                    ),
                  ),
                ),
              if (widget.selected) ...[
                // 旋转手柄 (顶部居中)
                Positioned(
                  left: boxW / 2 - handle / 2,
                  top: -rotateOffset,
                  child: GestureDetector(
                    onPanStart: (_) {
                      widget.onGestureStart?.call();
                      widget.onSelect();
                    },
                    onPanUpdate: (e) {
                      // 组件中心换算到画布显示坐标 (画布坐标 × viewScale)
                      final center = Offset(
                        (c.x + boxW / 2) * vs,
                        (c.y + boxH / 2) * vs,
                      );
                      final p = _toCanvasDisplay(e.globalPosition);
                      final angle =
                          math.atan2(p.dy - center.dy, p.dx - center.dx) *
                              180 /
                              math.pi;
                      // 归一化到 [-180, 180), 与属性面板滑杆范围一致
                      setState(() => _dragRotation = _normalizeAngle(angle + 90));
                      widget.onChanged(_effective);
                    },
                    onPanEnd: (_) {
                      widget.onChanged(_effective);
                      _dragRotation = null;
                      if (mounted) setState(() {});
                    },
                    child: _Handle(diameter: handle, color: Colors.green),
                  ),
                ),
                // 缩放手柄 (右下角)
                Positioned(
                  left: boxW - handle / 2,
                  top: boxH - handle / 2,
                  child: GestureDetector(
                    onPanStart: (_) {
                      widget.onGestureStart?.call();
                      widget.onSelect();
                    },
                    onPanUpdate: (e) {
                      final center = Offset(
                        (c.x + boxW / 2) * vs,
                        (c.y + boxH / 2) * vs,
                      );
                      final p = _toCanvasDisplay(e.globalPosition);
                      final dist = math.sqrt(math.pow(p.dx - center.dx, 2) +
                          math.pow(p.dy - center.dy, 2));
                      final baseDiag = math.sqrt(
                          math.pow(boxW * vs, 2) + math.pow(boxH * vs, 2));
                      final newScale =
                          (dist / (baseDiag / 2) * c.scale).clamp(0.2, 8.0);
                      setState(() => _dragScale = newScale.toDouble());
                      widget.onChanged(_effective);
                    },
                    onPanEnd: (_) {
                      widget.onChanged(_effective);
                      _dragScale = null;
                      if (mounted) setState(() {});
                    },
                    child: _Handle(diameter: handle, color: Colors.blue),
                  ),
                ),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// 角度归一化到 [-180, 180)
double _normalizeAngle(double deg) {
  var a = deg % 360;
  if (a > 180) a -= 360;
  if (a < -180) a += 360;
  return a;
}

/// 变换手柄圆点
class _Handle extends StatelessWidget {
  final double diameter;
  final Color color;
  const _Handle({required this.diameter, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
      );
}
