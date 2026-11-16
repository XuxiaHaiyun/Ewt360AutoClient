// 编辑器提交页冒烟测试
//
// 验证重写后的 EditorPage: 页面构建、整页适配缩放、画布尺寸弹窗改尺寸、
// 缩放控件、文本组件添加与选中、画笔模式绘制并固化为涂鸦组件、清空与撤销。
import 'package:ewt_auto_client/features/editor/domain/entities/editor_config.dart';
import 'package:ewt_auto_client/features/editor/presentation/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// 读取缩放浮层当前百分比 (工具栏高度会影响具体数值, 用相对断言更稳)
Finder _zoomPercentFinder() =>
    find.textContaining(RegExp(r'^\d+%$'));

double _readZoomPercent(WidgetTester tester) {
  final text = tester.widget<Text>(_zoomPercentFinder().first);
  return double.parse(text.data!.replaceAll('%', ''));
}

void main() {
  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EditorPage(
          initial: const EditorConfig(),
          onConfirm: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('页面构建: 工具栏 / 缩放浮层 / 空画布提示', (tester) async {
    await pumpEditor(tester);

    expect(find.text('编辑器提交'), findsOneWidget);
    expect(find.text('文本'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('公式'), findsOneWidget);
    expect(find.text('画笔'), findsOneWidget);
    expect(find.text('尺寸'), findsOneWidget);
    expect(find.text('背景'), findsOneWidget);
    // 默认整页适配, 缩放浮层显示百分比
    expect(_zoomPercentFinder(), findsOneWidget);
    // 空画布提示
    expect(find.textContaining('空白画布'), findsOneWidget);
  });

  testWidgets('画布尺寸弹窗: 选预设并确定后画布按新尺寸重适配', (tester) async {
    await pumpEditor(tester);
    final before = _readZoomPercent(tester);

    await tester.tap(find.text('尺寸'));
    await tester.pumpAndSettle();
    expect(find.text('画布大小'), findsOneWidget);

    // 默认 1080×1528 (高受限), 切到 1080×1080 后适配比例应变大
    await tester.tap(find.text('正方形 1080×1080'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '宽度 (px)'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('画布大小'), findsNothing);
    final after = _readZoomPercent(tester);
    expect(after, greaterThan(before));
  });

  testWidgets('缩放按钮: 放大 / 整页适配恢复', (tester) async {
    await pumpEditor(tester);
    final fitPercent = _readZoomPercent(tester);

    await tester.tap(find.byTooltip('放大'));
    await tester.pumpAndSettle();
    final zoomed = _readZoomPercent(tester);
    expect(zoomed, greaterThan(fitPercent));

    await tester.tap(find.byTooltip('整页适配'));
    await tester.pumpAndSettle();
    expect(_readZoomPercent(tester), fitPercent);
  });

  testWidgets('添加文本组件并选中, 属性面板出现', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.text('文本'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '你好画布');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 组件渲染在画布上
    expect(find.text('你好画布'), findsOneWidget);
    // 添加后自动选中, 属性面板出现
    expect(find.text('旋转'), findsOneWidget);
    expect(find.text('缩放'), findsOneWidget);
    expect(find.byTooltip('删除'), findsOneWidget);
  });

  testWidgets('画笔模式: 拖动绘制 → 完成绘制固化为涂鸦组件', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.text('画笔'));
    await tester.pumpAndSettle();
    expect(find.text('完成绘制'), findsOneWidget);
    // 画笔模式下空画布提示隐藏
    expect(find.textContaining('空白画布'), findsNothing);

    // 画布适配后位于视口中部, 在其内拖一笔
    await tester.dragFrom(const Offset(300, 200), const Offset(120, 80));
    await tester.pumpAndSettle();

    // 画笔栏横向溢出 (窄视口), 先从 "粗细" 文本处拖动滚动条, 露出 "完成绘制"
    await tester.drag(find.text('粗细'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成绘制'));
    await tester.pumpAndSettle();

    // 退出画笔模式, 笔画固化为组件并自动选中 (属性面板出现)
    expect(find.text('完成绘制'), findsNothing);
    expect(find.text('旋转'), findsOneWidget);
  });

  testWidgets('清空与撤销: 清空后可撤销恢复组件', (tester) async {
    await pumpEditor(tester);

    // 空画布: 清空按钮置灰 (onTap 为 null)
    InkWell clearInkWell() => tester.widget<InkWell>(
          find.ancestor(
            of: find.text('清空'),
            matching: find.byType(InkWell),
          ).first,
        );
    expect(clearInkWell().onTap, isNull);

    // 添加文本后清空可用
    await tester.tap(find.text('文本'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '待清空文本');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(clearInkWell().onTap, isNotNull);

    // 清空 → 组件消失 → 撤销恢复
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('待清空文本'), findsNothing);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('待清空文本'), findsOneWidget);
  });

  testWidgets('公式颜色: 选中公式后取色弹窗改色', (tester) async {
    final config = EditorConfig(
      components: [
        EditorComponent(
          id: 'f1',
          type: EditorComponentType.formula,
          x: 100,
          y: 150,
          width: 420,
          height: 140,
          latex: r'x^2 + y^2 = z^2',
          formulaFontSize: 40,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(home: EditorPage(initial: config, onConfirm: (_) {})),
    );
    await tester.pumpAndSettle();

    Color dotColor() => ((tester.widget<Container>(
              find.descendant(
                of: find.byTooltip('公式颜色'),
                matching: find.byWidgetPredicate(
                  (w) => w is Container && w.decoration is BoxDecoration,
                ),
              ).first,
            )).decoration as BoxDecoration)
          .color!;

    // 默认黑色圆点; 点击公式组件选中, 属性面板出现颜色圆点
    await tester.tapAt(tester.getCenter(find.byType(Math)));
    await tester.pumpAndSettle();
    expect(dotColor(), const Color(0xFF000000));

    // 打开取色弹窗 → 点红色 → 圆点变红
    await tester.tap(find.byTooltip('公式颜色'));
    await tester.pumpAndSettle();
    expect(find.text('选择公式颜色'), findsOneWidget);
    await tester.tap(find.byTooltip('红色'));
    await tester.pumpAndSettle();
    // 按 ARGB 值比较 (Color 与 MaterialColor 的 runtimeType 不同, == 不等)
    expect(dotColor().toARGB32(), Colors.red.toARGB32());

    // 撤销恢复黑色 (撤销会取消选中, 重新选中公式后读取)
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(Math)));
    await tester.pumpAndSettle();
    expect(dotColor().toARGB32(), const Color(0xFF000000).toARGB32());
  });
}
