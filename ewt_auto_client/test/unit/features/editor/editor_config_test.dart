import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ewt_auto_client/features/editor/domain/entities/editor_config.dart';

void main() {
  group('EditorConfig.resized', () {
    test('组件位置与尺寸按宽高比例等比缩放', () {
      // EditorComponent 构造器非常量, 含组件的配置不能用 const
      final config = EditorConfig(
        canvasWidth: 1080,
        canvasHeight: 1528,
        components: [
          EditorComponent(
            id: 'a',
            type: EditorComponentType.text,
            x: 100,
            y: 200,
            width: 300,
            height: 150,
            scale: 2,
            rotation: 45,
          ),
        ],
      );

      final resized = config.resized(540, 764);

      expect(resized.canvasWidth, 540);
      expect(resized.canvasHeight, 764);
      final c = resized.components.single;
      expect(c.x, 50);
      expect(c.y, 100);
      expect(c.width, 150);
      expect(c.height, 75);
      // scale / rotation / 类型保持不变
      expect(c.scale, 2);
      expect(c.rotation, 45);
      expect(c.type, EditorComponentType.text);
    });

    test('涂鸦笔画为组件内归一化坐标, 不受画布尺寸影响', () {
      final config = EditorConfig(
        canvasWidth: 1080,
        canvasHeight: 1080,
        components: [
          EditorComponent(
            id: 'd',
            type: EditorComponentType.doodle,
            x: 0,
            y: 0,
            width: 540,
            height: 540,
            doodleStrokes: [
              DoodleStroke(
                points: [OffsetN(0.1, 0.2), OffsetN(0.5, 0.6)],
                colorArgb: 0xFF000000,
                width: 3,
              ),
            ],
          ),
        ],
      );

      final resized = config.resized(2160, 2160);

      expect(resized.components.single.width, 1080);
      expect(
        resized.components.single.doodleStrokes!.single.points,
        config.components.single.doodleStrokes!.single.points,
      );
    });

    test('背景配置保持不变', () {
      const bg = EditorBackground(
        type: EditorBackgroundType.solid,
        color: Color(0xFF123456),
      );
      final resized =
          const EditorConfig(canvasWidth: 100, canvasHeight: 100, background: bg)
              .resized(200, 300);

      expect(resized.background.type, EditorBackgroundType.solid);
      expect(resized.background.color, const Color(0xFF123456));
    });

    test('空组件列表直接改尺寸', () {
      final resized = const EditorConfig().resized(800, 600);
      expect(resized.canvasWidth, 800);
      expect(resized.canvasHeight, 600);
      expect(resized.components, isEmpty);
    });

    test('旧尺寸非法时仅替换尺寸不缩放组件', () {
      final config = EditorConfig(
        canvasWidth: 0,
        canvasHeight: 0,
        components: [
          EditorComponent(
            id: 'a',
            type: EditorComponentType.text,
            x: 10,
            y: 20,
            width: 30,
            height: 40,
          ),
        ],
      );

      final resized = config.resized(1000, 500);

      expect(resized.canvasWidth, 1000);
      expect(resized.canvasHeight, 500);
      final c = resized.components.single;
      expect(c.x, 10);
      expect(c.y, 20);
      expect(c.width, 30);
      expect(c.height, 40);
    });

    test('缩小画布后组件坐标随比例缩小', () {
      final config = EditorConfig(
        canvasWidth: 2000,
        canvasHeight: 1000,
        components: [
          EditorComponent(
            id: 'a',
            type: EditorComponentType.image,
            x: 1000,
            y: 500,
            width: 600,
            height: 300,
          ),
        ],
      );

      final resized = config.resized(1000, 500);

      final c = resized.components.single;
      expect(c.x, 500);
      expect(c.y, 250);
      expect(c.width, 300);
      expect(c.height, 150);
    });
  });

  group('EditorConfig JSON 往返 (画布尺寸)', () {
    test('自定义画布尺寸经 toJson/fromJson 保持', () {
      final config = EditorConfig(
        canvasWidth: 1920,
        canvasHeight: 1080,
        components: [
          EditorComponent(
            id: 'a',
            type: EditorComponentType.text,
            x: 12.5,
            y: 34.5,
            width: 100,
            height: 60,
            text: 'hello',
          ),
        ],
      );

      final restored = EditorConfig.fromJson(config.toJson());

      expect(restored.canvasWidth, 1920);
      expect(restored.canvasHeight, 1080);
      expect(restored.components.single.x, 12.5);
      expect(restored.components.single.text, 'hello');
    });

    test('公式颜色经 toJson/fromJson 保持', () {
      final config = EditorConfig(
        components: [
          EditorComponent(
            id: 'f1',
            type: EditorComponentType.formula,
            latex: r'\frac{a}{b}',
            formulaColorArgb: 0xFF3366CC,
          ),
          EditorComponent(
            id: 'f2',
            type: EditorComponentType.formula,
            latex: 'x^2',
          ),
        ],
      );

      final restored = EditorConfig.fromJson(config.toJson());

      // 显式颜色保持; 未设置颜色的公式序列化后仍为 null (渲染默认黑)
      expect(restored.components[0].formulaColorArgb, 0xFF3366CC);
      expect(restored.components[1].formulaColorArgb, isNull);
    });

    test('缺失画布尺寸字段回退默认值', () {
      final restored = EditorConfig.fromJson({'components': []});
      expect(restored.canvasWidth, 1080);
      expect(restored.canvasHeight, 1528);
    });
  });
}
