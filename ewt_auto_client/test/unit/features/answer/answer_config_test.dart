/// 试题答案配置 (获取完成操作) 单元测试 (离线, 自包含)
///
/// 覆盖 [AnswerConfig] 的获取完成操作字段:
///   - [AnswerCompleteAction] 枚举与 [AnswerConfig.submitType] 映射
///   - [AnswerConfig.needAutoSubmit]
///   - submitQuestionTypes / imageUploadConfig 默认值与 copyWith
library;

import 'package:ewt_auto_client/features/answer/domain/entities/answer_config.dart';
import 'package:ewt_auto_client/features/answer/domain/entities/image_upload_config.dart';
import 'package:ewt_auto_client/features/answer/domain/services/answer_submit_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnswerCompleteAction 枚举', () {
    test('包含 无操作/提交做题痕迹/提交作答结果/导出 五项', () {
      // 2026-08 后新增 每课程单独导出 / 合并导出 两项
      expect(AnswerCompleteAction.values.length, 5);
      expect(AnswerCompleteAction.none.label, '无操作');
      expect(AnswerCompleteAction.trace.label, '提交做题痕迹');
      expect(AnswerCompleteAction.result.label, '提交作答结果');
      expect(AnswerCompleteAction.exportEach.label, '每课程单独导出');
      expect(AnswerCompleteAction.exportAll.label, '全部课程合并单文件导出');
    });
  });

  group('AnswerConfig 获取完成操作', () {
    test('默认无操作: 不自动提交, submitType 为 null', () {
      const cfg = AnswerConfig();
      expect(cfg.completeAction, AnswerCompleteAction.none);
      expect(cfg.needAutoSubmit, isFalse);
      expect(cfg.submitType, isNull);
      expect(cfg.submitQuestionTypes, isEmpty);
      expect(cfg.imageUploadConfig, isNull);
    });

    test('completeAction=trace → submitType=trace 且需要自动提交', () {
      const cfg = AnswerConfig(completeAction: AnswerCompleteAction.trace);
      expect(cfg.needAutoSubmit, isTrue);
      expect(cfg.submitType, SubmitType.trace);
    });

    test('completeAction=result → submitType=result', () {
      const cfg = AnswerConfig(completeAction: AnswerCompleteAction.result);
      expect(cfg.submitType, SubmitType.result);
    });

    test('completeAction=exportEach → exportMode=each, 无提交', () {
      const cfg =
          AnswerConfig(completeAction: AnswerCompleteAction.exportEach);
      expect(cfg.exportMode, AnswerExportMode.each);
      expect(cfg.submitType, isNull);
      expect(cfg.needAutoSubmit, isFalse);
    });

    test('completeAction=exportAll → exportMode=all, 无提交', () {
      const cfg = AnswerConfig(completeAction: AnswerCompleteAction.exportAll);
      expect(cfg.exportMode, AnswerExportMode.all);
      expect(cfg.submitType, isNull);
    });

    test('无操作/提交类操作 exportMode 均为 null', () {
      expect(const AnswerConfig().exportMode, isNull);
      expect(
        const AnswerConfig(completeAction: AnswerCompleteAction.trace)
            .exportMode,
        isNull,
      );
      expect(
        const AnswerConfig(completeAction: AnswerCompleteAction.result)
            .exportMode,
        isNull,
      );
    });

    test('枚举含 5 项且导出选项文案正确', () {
      expect(AnswerCompleteAction.values.length, 5);
      expect(AnswerCompleteAction.exportEach.label, '每课程单独导出');
      expect(AnswerCompleteAction.exportAll.label, '全部课程合并单文件导出');
    });

    test('copyWith 可切换获取完成操作', () {
      const cfg = AnswerConfig();
      final updated = cfg.copyWith(completeAction: AnswerCompleteAction.trace);
      expect(updated.submitType, SubmitType.trace);
      expect(updated.needAutoSubmit, isTrue);
    });

    test('copyWith 可设置题型筛选与图片上传配置', () {
      const cfg = AnswerConfig();
      final updated = cfg.copyWith(
        submitQuestionTypes: {'单选题', '多选题'},
        imageUploadConfig:
            const ImageUploadConfig(mode: ImageUploadMode.fixed),
      );
      expect(updated.submitQuestionTypes, {'单选题', '多选题'});
      expect(updated.imageUploadConfig?.mode, ImageUploadMode.fixed);
    });

    test('题型筛选为空集合表示全部题型', () {
      const cfg = AnswerConfig(submitQuestionTypes: {});
      expect(cfg.submitQuestionTypes.isEmpty, isTrue);
    });
  });
}
