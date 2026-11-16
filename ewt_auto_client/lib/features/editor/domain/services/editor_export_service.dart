/// 编辑器导出服务，把 EditorConfig 画布（背景 + 全部组件，无交互手柄）经 Overlay 屏幕外截图导出为 PNG。
/// 产物供"提交"流程作为主观题附件上传，失败返回 null。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../../presentation/canvas_background.dart';
import '../entities/editor_config.dart';

/// 编辑器导出服务
///
/// 把 [EditorConfig] 渲染为 PNG 字节, 供"提交"流程作为主观题附件图片上传
/// (与 [ImageGenerationService] 的 generate 模式产物一致)。
class EditorExportService {
  static final EditorExportService instance = EditorExportService._();
  EditorExportService._();

  /// 渲染整页画布 (背景 + 全部组件, 无交互手柄) 为 widget
  static Widget buildCanvas(EditorConfig config) {
    return SizedBox(
      width: config.canvasWidth,
      height: config.canvasHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: buildEditorBackgroundWidget(
              config.background,
              config.canvasWidth,
              config.canvasHeight,
            ),
          ),
          ...config.components.map(_buildComponent),
        ],
      ),
    );
  }

  static Widget _buildComponent(EditorComponent c) {
    final child = buildComponentWidget(c.copyWith(
      width: c.width * c.scale,
      height: c.height * c.scale,
      textFontSize: (c.textFontSize ?? 24) * c.scale,
      formulaFontSize: (c.formulaFontSize ?? 24) * c.scale,
    ));
    return Positioned(
      left: c.x,
      top: c.y,
      width: c.width * c.scale,
      height: c.height * c.scale,
      child: Transform.rotate(
        angle: c.rotation * 3.141592653589793 / 180,
        child: child,
      ),
    );
  }

  /// 导出 PNG 字节
  ///
  /// 通过 Overlay 屏幕外截图, 失败返回 null。
  Future<Uint8List?> exportPng(
    BuildContext context,
    EditorConfig config, {
    Duration imageLoadTimeout = const Duration(seconds: 6),
  }) async {
    OverlayEntry? entry;
    try {
      final overlay = Overlay.of(context, rootOverlay: true);
      final boundaryKey = GlobalKey();
      entry = OverlayEntry(
        builder: (_) => Positioned(
          left: -10000,
          top: -10000,
          child: Material(
            color: Colors.white,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                widthFactor: 1,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: buildCanvas(config),
                ),
              ),
            ),
          ),
        ),
      );
      overlay.insert(entry);
      final end = DateTime.now().add(imageLoadTimeout);
      while (DateTime.now().isBefore(end)) {
        WidgetsBinding.instance.scheduleFrame();
        await Future.delayed(const Duration(milliseconds: 200));
      }
      final boundary = boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null || !boundary.attached || !boundary.hasSize) {
        return null;
      }
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      entry?.remove();
    }
  }
}
