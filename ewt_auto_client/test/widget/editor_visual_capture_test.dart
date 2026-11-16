// 编辑器提交页视觉截图生成 (非断言测试)
//
// 渲染 EditorPage 在 手机默认/组件编辑/画笔模式/桌面/尺寸弹窗 下的截图,
// 输出到 build/visual/*.png 供视觉验收使用。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ewt_auto_client/features/editor/domain/entities/editor_config.dart';
import 'package:ewt_auto_client/features/editor/presentation/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _outDir = 'build/visual';
const _testFontFamily = 'VisualTestFont';
const _captureKey = ValueKey('editor_visual_capture_root');

void main() {
  setUpAll(() async {
    // 加载系统中文语系字体 (微软雅黑), 截图文字可读
    try {
      final bytes = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
      final loader = FontLoader(_testFontFamily)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {
      // 字体加载失败时退化 Ahem, 不阻塞
    }
    // 加载 MaterialIcons 字体
    try {
      final exe = File(Platform.resolvedExecutable).parent.path;
      final iconFont = File(
        '$exe/../../material_fonts/MaterialIcons-Regular.otf',
      );
      if (iconFont.existsSync()) {
        final bytes = await iconFont.readAsBytes();
        final loader = FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.view(bytes.buffer)));
        await loader.load();
      }
    } catch (_) {
      // 加载失败时图标显示为占位方块, 不阻塞
    }
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    required Size size,
    EditorConfig? config,
  }) async {
    const dpr = 2.0;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = size * dpr;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: _testFontFamily,
            useMaterial3: true,
          ),
          home: EditorPage(
            initial: config ?? const EditorConfig(),
            onConfirm: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await tester.runAsync(
      () => boundary.toImage(pixelRatio: 2.0),
    );
    ByteData? bytes;
    if (image != null) {
      bytes = await tester.runAsync<ByteData?>(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
    }
    if (bytes == null) fail('截图编码失败');
    final dir = Directory(_outDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$_outDir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
  }

  EditorConfig demoConfig() => EditorConfig(
        components: [
          EditorComponent(
            id: 't1',
            type: EditorComponentType.text,
            x: 80,
            y: 120,
            width: 620,
            height: 140,
            text: '解: 设速度为 x 千米/小时',
            textFontSize: 40,
          ),
          EditorComponent(
            id: 'f1',
            type: EditorComponentType.formula,
            x: 120,
            y: 320,
            width: 420,
            height: 140,
            latex: r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}',
            formulaFontSize: 44,
          ),
          EditorComponent(
            id: 'd1',
            type: EditorComponentType.doodle,
            x: 560,
            y: 520,
            width: 320,
            height: 260,
            doodleBackground: const EditorBackground(
              type: EditorBackgroundType.solid,
              color: Color(0x00000000),
            ),
            doodleStrokes: [
              const DoodleStroke(
                points: [
                  OffsetN(0.05, 0.8),
                  OffsetN(0.3, 0.2),
                  OffsetN(0.55, 0.7),
                  OffsetN(0.8, 0.15),
                  OffsetN(0.95, 0.6),
                ],
                colorArgb: 0xFF1A1A1A,
                width: 6,
              ),
            ],
          ),
          EditorComponent(
            id: 'i1',
            type: EditorComponentType.image,
            x: 120,
            y: 620,
            width: 360,
            height: 270,
          ),
        ],
      );

  testWidgets('手机默认 (空画布整页适配)', (tester) async {
    await pumpEditor(tester, size: const Size(412, 892));
    await capture(tester, 'editor_phone_default');
  });

  testWidgets('手机组件编辑 (文本选中 + 属性面板)', (tester) async {
    await pumpEditor(tester, size: const Size(412, 892), config: demoConfig());
    // 选中第一个文本组件
    final textCenter = tester.getCenter(find.text('解: 设速度为 x 千米/小时'));
    await tester.tapAt(textCenter);
    await tester.pumpAndSettle();
    await capture(tester, 'editor_phone_components');
  });

  testWidgets('手机画笔模式 (已画一笔)', (tester) async {
    await pumpEditor(tester, size: const Size(412, 892), config: demoConfig());
    await tester.tap(find.text('画笔'));
    await tester.pumpAndSettle();
    // 画布中部画一笔
    await tester.dragFrom(const Offset(200, 400), const Offset(120, 90));
    await tester.pumpAndSettle();
    await capture(tester, 'editor_phone_penmode');
  });

  testWidgets('桌面默认 (空画布)', (tester) async {
    await pumpEditor(tester, size: const Size(800, 600));
    await capture(tester, 'editor_desktop_default');
  });

  testWidgets('画布大小弹窗', (tester) async {
    await pumpEditor(tester, size: const Size(412, 892));
    await tester.tap(find.text('尺寸'));
    await tester.pumpAndSettle();
    await capture(tester, 'editor_size_dialog');
  });
}
