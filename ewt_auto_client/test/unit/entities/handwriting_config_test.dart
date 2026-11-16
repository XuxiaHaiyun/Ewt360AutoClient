/// 手写模拟 & 图片上传配置实体测试 (离线)
///
/// 覆盖 [HandwritingConfig]/[HandwritingFontConfig] 的 JSON 序列化往返与容错,
/// 以及 [ImageUploadConfig.copyWith] 的 handwriting 哨兵字段逻辑。
library;

import 'dart:ui' show Color;

import 'package:ewt_auto_client/features/answer/domain/entities/handwriting_config.dart';
import 'package:ewt_auto_client/features/answer/domain/entities/image_upload_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HandwritingConfig 序列化', () {
    test('序列化往返: 默认配置一致', () {
      const config = HandwritingConfig();
      final back = HandwritingConfig.fromJson(config.toJson());
      expect(back, config);
    });

    test('序列化往返: 含自定义字体/颜色/枚举/涂改', () {
      const config = HandwritingConfig(
        font: HandwritingFontConfig.custom('C:/fonts/my.ttf'),
        fontSize: 40,
        inkColor: Color(0xFF123456),
        paperType: HandwritingPaperType.tianzige,
        paperColor: Color(0xFFF0F9F0),
        paperLineColor: Color(0xFFA5C89A),
        scratchOut: true,
        scratchOutStyle: ScratchOutStyle.wave,
        scratchOutCount: 5,
        scratchOutColor: Color(0xFFC62828),
        imageCurvature: 0.5,
        randomSeed: 12345,
        scale: 0.75,
      );
      final json = config.toJson();
      final back = HandwritingConfig.fromJson(json);
      expect(back, config);
      // 关键字段显式校验
      expect(back.font.source, HandwritingFontSource.custom);
      expect(back.font.customPath, 'C:/fonts/my.ttf');
      expect(back.paperType, HandwritingPaperType.tianzige);
      expect(back.scratchOutStyle, ScratchOutStyle.wave);
      expect(back.inkColor, const Color(0xFF123456));
    });

    test('反序列化容错: 空 map 回退默认', () {
      final back = HandwritingConfig.fromJson({});
      expect(back, const HandwritingConfig());
    });

    test('反序列化容错: 非法枚举名回退默认', () {
      final back = HandwritingConfig.fromJson({
        'paperType': 'not_a_real_type',
        'scratchOutStyle': 'nope',
      });
      expect(back.paperType, HandwritingPaperType.ruled);
      expect(back.scratchOutStyle, ScratchOutStyle.singleLine);
    });
  });

  group('ImageUploadConfig.copyWith handwriting 哨兵', () {
    const hw = HandwritingConfig();

    test('显式传 null 能清空 handwriting (关闭手写模拟开关)', () {
      const config = ImageUploadConfig(
        mode: ImageUploadMode.generate,
        handwriting: hw,
      );
      expect(config.handwriting, isNotNull);

      final cleared = config.copyWith(handwriting: null);
      expect(cleared.handwriting, isNull);
    });

    test('传具体配置能设置 handwriting', () {
      const config = ImageUploadConfig();
      expect(config.handwriting, isNull);

      final set = config.copyWith(handwriting: hw);
      expect(set.handwriting, hw);
    });

    test('不传 handwriting 保留原值', () {
      const config = ImageUploadConfig(
        mode: ImageUploadMode.generate,
        handwriting: hw,
      );
      final kept = config.copyWith(mode: ImageUploadMode.custom);
      expect(kept.handwriting, hw);
      expect(kept.mode, ImageUploadMode.custom);
    });
  });
}
