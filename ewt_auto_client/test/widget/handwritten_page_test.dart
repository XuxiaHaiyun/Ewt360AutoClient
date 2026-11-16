/// 手写模拟渲染组件测试
///
/// 验证 [HandwrittenPage]:
/// - 无网络图片时能完成布局并渲染 (不抛异常)
/// - 渲染尺寸随内容变化
/// - 可将渲染结果导出 PNG 到临时目录 (debug/text-to-handwriting)
///   供人工检查视觉效果
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:ewt_auto_client/features/answer/domain/entities/handwriting_config.dart';
import 'package:ewt_auto_client/features/answer/presentation/widgets/handwritten_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sampleHtml =
      '<p>解：设函数 f(x) = 2x<sup>3</sup> − 3x<sup>2</sup> + 1，则 f′(x) = 6x<sup>2</sup> − 6x。</p>'
      '<p>令 f′(x) = 0，得 x₁ = 0，x₂ = 1。经检验，f(x) 在 [0, 1] 上单调递减，'
      '故最大值为 f(0) = 1，答案见解析。</p>'
      '<p>This is a test with English words and numbers 123456.</p>';

  Future<RenderRepaintBoundary?> pumpPage(
    WidgetTester tester,
    HandwritingConfig config,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: HandwrittenPage(
            html: sampleHtml,
            config: config,
            width: 600,
          ),
        ),
      ),
    ));
    // 等待异步布局 (字体解析 + 图片加载 + setState) 完成
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    return key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  }

  testWidgets('手写渲染: 布局完成且尺寸合理', (tester) async {
    final boundary = await pumpPage(
      tester,
      const HandwritingConfig(
        paperType: HandwritingPaperType.ruled,
        scratchOut: true,
        scratchOutCount: 2,
      ),
    );
    expect(boundary, isNotNull, reason: 'HandwrittenPage 应完成布局');
    if (boundary == null) return;
    expect(boundary.hasSize, isTrue);
    expect(boundary.size.width, greaterThan(0));
    expect(boundary.size.height, greaterThan(100),
        reason: '内容高度应超过初始占位高度');
  });

  testWidgets('手写渲染: 不同配置高度不同 (字号/行距生效)', (tester) async {
    final small = await pumpPage(
      tester,
      const HandwritingConfig(fontSize: 20, lineHeight: 1.3),
    );
    final smallH = small?.size.height ?? 0;

    final large = await pumpPage(
      tester,
      const HandwritingConfig(fontSize: 44, lineHeight: 2.4),
    );
    final largeH = large?.size.height ?? 0;
    expect(largeH, greaterThan(smallH), reason: '大字号+大行距应产生更高页面');
  });

  testWidgets('手写渲染: 导出 PNG 供人工检查 (仅本机临时目录)', (tester) async {
    final boundary = await pumpPage(
      tester,
      const HandwritingConfig(
        font: HandwritingFontConfig.bundled('ma_shan_zheng'),
        paperType: HandwritingPaperType.tianzige,
        paperColor: Color(0xFFFFF8E7),
        scratchOut: true,
        scratchOutCount: 2,
        scratchOutStyle: ScratchOutStyle.wave,
        tiltAngle: 4,
        fontSize: 28,
      ),
    );
    expect(boundary, isNotNull);
    if (boundary == null) return;

    await tester.binding.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(data, isNotNull);
      final bytes = data!.buffer.asUint8List();
      expect(bytes.length, greaterThan(1000));

      final dir = Directory('debug/text-to-handwriting');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/preview_sample.png');
      await file.writeAsBytes(bytes);
      // ignore: avoid_print
      print('PNG 已导出: ${file.absolute.path} (${bytes.length} bytes)');
    });
  });
}
