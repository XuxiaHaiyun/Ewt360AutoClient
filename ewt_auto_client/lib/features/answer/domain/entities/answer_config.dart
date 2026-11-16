/// 答案获取配置实体：获取方案、展示字段、获取完成操作（提交做题痕迹/作答结果/导出 PDF）及题型筛选。
/// label 文案不得包含内部接口名等技术细节；[AnswerConfig.submitType]/[AnswerConfig.exportMode] 供提交与导出服务使用。
library;

import 'answer_filter_config.dart';
import 'image_upload_config.dart';
import '../services/answer_submit_service.dart';

/// 答案获取方案
///
/// label 为用户可见文案, 不得包含内部接口名/回退链等技术细节
/// (内部实现见 [AnswerMethod.value] 与 answer_service)。
enum AnswerMethod {
  /// 自动方案: 按优先级依次尝试 越权方案(escalation) → favorites → direct,
  /// 任一方案成功即停止, 失败自动回退到下一方案。
  auto('auto', '自动 (推荐)'),
  direct('direct', '直接获取'),
  escalation('escalation', '增强方案'),
  favorites('favorites', '备用方案'),
  download('download', '试卷方案');

  final String value;
  final String label;
  const AnswerMethod(this.value, this.label);
}

/// 获取完成操作 (获取答案完成后自动执行的动作)
enum AnswerCompleteAction {
  /// 无操作: 仅获取答案, 不提交不导出
  none('none', '无操作'),

  /// 提交做题痕迹 (仅保存答案, 不交卷)
  trace('trace', '提交做题痕迹'),

  /// 提交作答结果 (保存答案 + 最终交卷)
  result('result', '提交作答结果'),

  /// 每课程单独导出 (每个课程导出一个 PDF 文件)
  exportEach('export_each', '每课程单独导出'),

  /// 全部课程合并单文件导出 (合并为一个 PDF)
  exportAll('export_all', '全部课程合并单文件导出');

  final String value;
  final String label;
  const AnswerCompleteAction(this.value, this.label);
}

/// 获取完成操作的导出模式
enum AnswerExportMode {
  /// 每课程单独导出
  each,

  /// 全部课程合并单文件导出
  all,
}

/// 常见题目题型 (用于"获取完成操作-提交配置"的题型筛选)
///
/// 空集合表示"全部题型" (提交时不做题型过滤)。
const List<String> kAnswerQuestionTypeOptions = [
  '单选题',
  '多选题',
  '判断题',
  '填空题',
  '解答题',
  '计算题',
  '简答题',
  '实验题',
  '阅读理解',
  '完形填空',
  '名句默写',
  '作文',
  '听力',
];

/// 答案获取配置
///
/// [method] 获取方案
/// [showQuestionContent] 是否展示/导出原题目
/// [showOptions] 是否展示/导出选项
/// [showAnswer] 是否展示/导出答案
/// [showKnowledge] 是否展示/导出知识点
/// [showDifficulty] 是否展示/导出难度
/// [showAnalysis] 是否展示/导出解析
/// [completeAction] 获取完成操作 (无操作/提交做题痕迹/提交作答结果)
/// [submitQuestionTypes] 提交时的题型筛选 (空集合 = 全部题型)
/// [imageUploadConfig] 提交时图片上传类题型的方案配置 (null = 不上传图片)
class AnswerConfig {
  final AnswerMethod method;
  final bool showQuestionContent;
  final bool showOptions;
  final bool showAnswer;
  final bool showKnowledge;
  final bool showDifficulty;
  final bool showAnalysis;
  final AnswerCompleteAction completeAction;
  final Set<String> submitQuestionTypes;
  final ImageUploadConfig? imageUploadConfig;

  const AnswerConfig({
    this.method = AnswerMethod.auto,
    this.showQuestionContent = true,
    this.showOptions = true,
    this.showAnswer = true,
    this.showKnowledge = true,
    this.showDifficulty = true,
    this.showAnalysis = true,
    this.completeAction = AnswerCompleteAction.none,
    this.submitQuestionTypes = const {},
    this.imageUploadConfig,
  });

  AnswerConfig copyWith({
    AnswerMethod? method,
    bool? showQuestionContent,
    bool? showOptions,
    bool? showAnswer,
    bool? showKnowledge,
    bool? showDifficulty,
    bool? showAnalysis,
    AnswerCompleteAction? completeAction,
    Set<String>? submitQuestionTypes,
    ImageUploadConfig? imageUploadConfig,
  }) {
    return AnswerConfig(
      method: method ?? this.method,
      showQuestionContent: showQuestionContent ?? this.showQuestionContent,
      showOptions: showOptions ?? this.showOptions,
      showAnswer: showAnswer ?? this.showAnswer,
      showKnowledge: showKnowledge ?? this.showKnowledge,
      showDifficulty: showDifficulty ?? this.showDifficulty,
      showAnalysis: showAnalysis ?? this.showAnalysis,
      completeAction: completeAction ?? this.completeAction,
      submitQuestionTypes: submitQuestionTypes ?? this.submitQuestionTypes,
      imageUploadConfig: imageUploadConfig ?? this.imageUploadConfig,
    );
  }

  /// 是否需要在获取完成后自动提交 (仅提交类操作)
  bool get needAutoSubmit => submitType != null;

  /// 提交类型 (供 AnswerSubmitService 使用), null 表示无需提交
  SubmitType? get submitType => switch (completeAction) {
    AnswerCompleteAction.none => null,
    AnswerCompleteAction.trace => SubmitType.trace,
    AnswerCompleteAction.result => SubmitType.result,
    AnswerCompleteAction.exportEach => null,
    AnswerCompleteAction.exportAll => null,
  };

  /// 导出模式 (每课程单独 / 全部合并), null 表示无需导出
  AnswerExportMode? get exportMode => switch (completeAction) {
    AnswerCompleteAction.none => null,
    AnswerCompleteAction.trace => null,
    AnswerCompleteAction.result => null,
    AnswerCompleteAction.exportEach => AnswerExportMode.each,
    AnswerCompleteAction.exportAll => AnswerExportMode.all,
  };
}

/// 答案获取配置页返回值 (方案配置 + 过滤配置)
///
/// 对应原 AnswerConfigDialog (方案+字段) + AnswerFilterDialog (过滤) 的合并,
/// 用户在单一页面内完成所有配置后一次性返回。
class AnswerConfigResult {
  final AnswerConfig config;
  final AnswerFilterConfig filterConfig;

  const AnswerConfigResult({required this.config, required this.filterConfig});
}
