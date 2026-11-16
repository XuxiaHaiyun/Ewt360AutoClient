/// 图片上传类题型（主观题 attachmentImages）的上传方案配置：固定图片/按答案解析生成/自定义图片/编辑器导出。
/// 关键约束：copyWith 用哨兵 `_handwritingKeep` 区分"未传"与"显式传 null"（后者表示关闭手写模拟）。
library;

import 'dart:typed_data';

import 'handwriting_config.dart';
import '../../../editor/domain/entities/editor_config.dart';

/// 哨兵常量: 区分 [ImageUploadConfig.copyWith] 中 "未传 handwriting" 与 "显式传 null"。
///
/// 手写模拟开关需要能把 handwriting 显式置空 (关闭手写模拟), 而 copyWith 对
/// 其他字段的语义是 "传 null 表示保留原值", 二者冲突, 故用哨兵单独处理 handwriting。
const Object _handwritingKeep = Object();

/// 图片上传类题型的图片上传方案配置
///
/// 用于"提交做题痕迹/答题结果"时为主观题 (subjective=true) 设置 attachmentImages。
///
/// 支持三种上传方案:
/// - [ImageUploadMode.fixed]: 使用固定图片 (默认 assets/images/onlyhead.png)
/// - [ImageUploadMode.generate]: 根据题目答案/解析动态生成图片
///   (可选择显示"答案"和/或"解析"内容, 但生成的图片中不出现"答案"和"解析"字样)
/// - [ImageUploadMode.custom]: 用户从本机选择自定义图片 (可多张),
///   按 [customAssignment] 策略分配到主观题
///
/// generate 模式的附加选项:
/// - [hideAnswerContainsAnalysis]: 答案含"见解析"字样时不生成答案内容
/// - [handwriting]: 手写模拟配置 (非 null 时答案/解析以手写风格渲染)
class ImageUploadConfig {
  /// 上传模式
  final ImageUploadMode mode;

  /// 固定图片路径 (mode=fixed 时使用, 默认 assets/images/onlyhead.png)
  final String fixedImagePath;

  /// 是否包含答案内容 (mode=generate 时使用)
  final bool includeAnswer;

  /// 是否包含解析内容 (mode=generate 时使用)
  final bool includeAnalysis;

  /// 答案含"见解析"时不展示 (mode=generate 时使用)
  ///
  /// 勾选后, 若某题答案文本包含"见解析"字样, 该题的答案内容
  /// 自动从生成图片中剔除 (解析仍按 includeAnalysis 决定)。
  final bool hideAnswerContainsAnalysis;

  /// 仅特定学科显示解析 (mode=generate 时使用)
  ///
  /// 空集合 = 全部学科都在生成图片中显示解析;
  /// 非空时, 仅学科名 (来自课程 subjectName) 命中该集合的题目,
  /// 其生成图片才包含解析内容 (答案内容不受影响)。
  final Set<String> analysisSubjects;

  /// 手写模拟配置 (mode=generate 时使用, null = 关闭手写模拟)
  ///
  /// 启用后, 答案/解析内容以接近真实手写的风格渲染:
  /// 自定义手写字体、逐字倾斜/起伏/字号变化、涂改、纸张背景、
  /// 公式与图片模拟手绘等, 参数详见 [HandwritingConfig]。
  final HandwritingConfig? handwriting;

  /// 编辑器配置 (mode=editor 时使用)
  ///
  /// 以画布为中心的集成编辑器产物: 文本/图片/公式/涂鸦作为可移动/缩放/旋转的
  /// 组件, 画布背景支持纯色/自定义颜色/自定义图片/手写模拟同款纸张。
  /// 导出为 PNG 作为主观题附件上传。
  final EditorConfig? editor;

  /// 自定义图片字节列表 (mode=custom 时使用, 用户从本机选择)
  ///
  /// 与 [customImageNames] 一一对应。用于 [CustomImageAssignment.allShared]
  /// 分配策略 (所有主观题都同时上传这几张图片)。
  final List<Uint8List> customImageBytes;

  /// 自定义图片文件名列表 (mode=custom 时使用, 用于 OSS 上传命名)
  ///
  /// 与 [customImageBytes] 一一对应。
  final List<String> customImageNames;

  /// 自定义图片分配策略 (mode=custom 时使用, 默认全部相同)
  final CustomImageAssignment customAssignment;

  /// 手动分配: questionId → 图片字节列表 (mode=custom + manual 时使用)
  ///
  /// 为每道主观题单独选择的图片 (可多张), key 为主观题 id。
  /// 与 [manualImageNames] 的 key 一一对应。
  final Map<String, List<Uint8List>> manualImageBytes;

  /// 手动分配: questionId → 图片文件名列表 (用于 OSS 上传命名)
  final Map<String, List<String>> manualImageNames;

  const ImageUploadConfig({
    this.mode = ImageUploadMode.fixed,
    this.fixedImagePath = 'assets/images/onlyhead.png',
    this.includeAnswer = true,
    this.includeAnalysis = false,
    this.hideAnswerContainsAnalysis = false,
    this.analysisSubjects = const {},
    this.handwriting,
    this.editor,
    this.customImageBytes = const [],
    this.customImageNames = const [],
    this.customAssignment = CustomImageAssignment.allShared,
    this.manualImageBytes = const {},
    this.manualImageNames = const {},
  });

  /// 是否启用图片上传 (任何模式都视为启用)
  bool get enabled => true;

  /// generate 模式下, 指定学科是否应在生成图片中显示解析
  ///
  /// [analysisSubjects] 为空 = 全部学科显示解析;
  /// 非空时仅命中集合的学科显示解析。
  bool shouldShowAnalysisFor(String subjectName) =>
      includeAnalysis &&
      (analysisSubjects.isEmpty || analysisSubjects.contains(subjectName));

  /// 自定义图片数量 (便捷访问, 仅 allShared 策略的池)
  int get customImageCount => customImageBytes.length;

  /// 手动分配已配置的题目数 (便捷访问)
  int get manualConfiguredCount => manualImageBytes.length;

  /// 拷贝并覆盖指定字段
  ImageUploadConfig copyWith({
    ImageUploadMode? mode,
    String? fixedImagePath,
    bool? includeAnswer,
    bool? includeAnalysis,
    bool? hideAnswerContainsAnalysis,
    Set<String>? analysisSubjects,
    // 哨兵区分 "未传" 与 "显式 null": null 表示关闭手写模拟, 必须能清空
    Object? handwriting = _handwritingKeep,
    EditorConfig? editor,
    List<Uint8List>? customImageBytes,
    List<String>? customImageNames,
    CustomImageAssignment? customAssignment,
    Map<String, List<Uint8List>>? manualImageBytes,
    Map<String, List<String>>? manualImageNames,
  }) {
    return ImageUploadConfig(
      mode: mode ?? this.mode,
      fixedImagePath: fixedImagePath ?? this.fixedImagePath,
      includeAnswer: includeAnswer ?? this.includeAnswer,
      includeAnalysis: includeAnalysis ?? this.includeAnalysis,
      hideAnswerContainsAnalysis:
          hideAnswerContainsAnalysis ?? this.hideAnswerContainsAnalysis,
      analysisSubjects: analysisSubjects ?? this.analysisSubjects,
      // 显式传 null → 清空手写模拟; 未传 → 保留原值
      handwriting: identical(handwriting, _handwritingKeep)
          ? this.handwriting
          : (handwriting is HandwritingConfig ? handwriting : null),
      editor: editor ?? this.editor,
      customImageBytes: customImageBytes ?? this.customImageBytes,
      customImageNames: customImageNames ?? this.customImageNames,
      customAssignment: customAssignment ?? this.customAssignment,
      manualImageBytes: manualImageBytes ?? this.manualImageBytes,
      manualImageNames: manualImageNames ?? this.manualImageNames,
    );
  }
}

/// 图片上传模式
enum ImageUploadMode {
  /// 固定图片 (使用 assets/images/onlyhead.png 或自定义路径)
  fixed,

  /// 根据答案/解析内容动态生成图片
  generate,

  /// 用户从本机选择自定义图片 (可多张), 按 [CustomImageAssignment] 策略分配
  custom,

  /// 编辑器提交: 以画布为中心的集成编辑器 (文本/图片/公式/涂鸦组件),
  /// 导出 PNG 作为主观题附件上传
  editor,
}

/// 自定义图片分配策略 (mode=custom 时使用)
enum CustomImageAssignment {
  /// 全部题相同: 每道主观题都使用全部选中的图片 (attachmentImages = 全部 URL)
  ///
  /// 支持多选图片, 所有主观题都同时上传这几张图片。
  allShared,

  /// 手动分配: 为每道主观题单独选择图片 (可多张), 存于 manualImageBytes
  manual,
}