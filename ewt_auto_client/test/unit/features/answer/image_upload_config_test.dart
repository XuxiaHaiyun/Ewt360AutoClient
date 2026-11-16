/// 图片上传配置 (仅特定学科显示解析) 单元测试 (离线, 自包含)
///
/// 覆盖 [ImageUploadConfig.analysisSubjects] 与 [ImageUploadConfig.shouldShowAnalysisFor]:
///   - 空集合 = 全部学科显示解析
///   - 非空集合 = 仅命中学科显示解析
///   - includeAnalysis=false 时一律不显示解析
library;

import 'package:ewt_auto_client/features/answer/domain/entities/image_upload_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('analysisSubjects 默认值', () {
    test('默认空集合 (全部学科显示解析)', () {
      const cfg = ImageUploadConfig();
      expect(cfg.analysisSubjects, isEmpty);
      // includeAnalysis 默认 false → 不显示解析
      expect(cfg.shouldShowAnalysisFor('语文'), isFalse);
      // 开启 includeAnalysis 后, 空集合 → 全部学科都显示解析
      const cfg2 = ImageUploadConfig(includeAnalysis: true);
      expect(cfg2.shouldShowAnalysisFor('语文'), isTrue);
      expect(cfg2.shouldShowAnalysisFor('数学'), isTrue);
    });
  });

  group('shouldShowAnalysisFor 学科过滤', () {
    test('非空集合: 仅命中学科显示解析', () {
      const cfg = ImageUploadConfig(
        includeAnalysis: true,
        analysisSubjects: {'语文', '数学'},
      );
      expect(cfg.shouldShowAnalysisFor('语文'), isTrue);
      expect(cfg.shouldShowAnalysisFor('数学'), isTrue);
      expect(cfg.shouldShowAnalysisFor('英语'), isFalse);
      expect(cfg.shouldShowAnalysisFor(''), isFalse);
    });

    test('includeAnalysis=false 时学科集合无效', () {
      const cfg = ImageUploadConfig(analysisSubjects: {'语文'});
      expect(cfg.shouldShowAnalysisFor('语文'), isFalse);
    });

    test('copyWith 可更新学科集合', () {
      const cfg = ImageUploadConfig(includeAnalysis: true);
      final updated = cfg.copyWith(analysisSubjects: {'物理'});
      expect(updated.shouldShowAnalysisFor('物理'), isTrue);
      expect(updated.shouldShowAnalysisFor('语文'), isFalse);
    });
  });
}
