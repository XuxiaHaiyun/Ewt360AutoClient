/// 编辑器画布配置实体：画布尺寸、背景（纯色/自定义颜色/图片/手写纸张）及文本/图片/公式/涂鸦组件列表。
/// 支持与 HandwritingConfig 同款纸张样式，组件与背景均可 JSON 序列化持久化。
library;

import 'dart:convert' show base64Encode, base64Decode;
import 'dart:typed_data';
import 'dart:ui' show Color;

import '../../../answer/domain/entities/handwriting_config.dart';

/// 编辑器画布背景类型
enum EditorBackgroundType {
  /// 纯色背景 (可自定义颜色)
  solid,

  /// 自定义颜色 (与 solid 类似, 但 UI 引导选择任意色, 这里直接用 color 字段)
  customColor,

  /// 自定义图片作为背景
  customImage,

  /// 手写模拟同款纸张背景 (横线/方格/田字格/空白, 纸色线色可调)
  handwritingPaper,
}

/// 编辑器画布背景
///
/// 与"手写模拟"共用 [HandwritingPaperType] 表达纸张样式 (handwritingPaper 模式)。
/// 自定义图片以 base64 字节存储 (便于 JSON 持久化)。
class EditorBackground {
  final EditorBackgroundType type;

  /// 纯色 / 自定义颜色 (type=solid/customColor 时有效)
  final Color color;

  /// 自定义图片字节 (type=customImage 时有效)
  final Uint8List? imageBytes;

  /// 自定义图片文件名 (导出命名用)
  final String? imageName;

  /// 纸张类型 (type=handwritingPaper 时有效, 复用手写模拟纸张)
  final HandwritingPaperType paperType;

  /// 纸张颜色 (handwritingPaper 有效)
  final Color paperColor;

  /// 纸张线条颜色 (handwritingPaper 有效)
  final Color paperLineColor;

  /// 纸张线条间距 (px, handwritingPaper 有效)
  final double paperLineSpacing;

  const EditorBackground({
    this.type = EditorBackgroundType.handwritingPaper,
    this.color = const Color(0xFFFFFFFF),
    this.imageBytes,
    this.imageName,
    this.paperType = HandwritingPaperType.ruled,
    this.paperColor = const Color(0xFFFFFFFF),
    this.paperLineColor = const Color(0xFF8FB6E8),
    this.paperLineSpacing = 58,
  });

  EditorBackground copyWith({
    EditorBackgroundType? type,
    Color? color,
    Uint8List? imageBytes,
    bool clearImage = false,
    String? imageName,
    HandwritingPaperType? paperType,
    Color? paperColor,
    Color? paperLineColor,
    double? paperLineSpacing,
  }) {
    return EditorBackground(
      type: type ?? this.type,
      color: color ?? this.color,
      imageBytes: clearImage ? null : (imageBytes ?? this.imageBytes),
      imageName: imageName ?? this.imageName,
      paperType: paperType ?? this.paperType,
      paperColor: paperColor ?? this.paperColor,
      paperLineColor: paperLineColor ?? this.paperLineColor,
      paperLineSpacing: paperLineSpacing ?? this.paperLineSpacing,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'color': color.toARGB32(),
        if (imageBytes != null) 'imageBase64': base64Encode(imageBytes!),
        if (imageName != null) 'imageName': imageName,
        'paperType': paperType.name,
        'paperColor': paperColor.toARGB32(),
        'paperLineColor': paperLineColor.toARGB32(),
        'paperLineSpacing': paperLineSpacing,
      };

  static EditorBackground fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String?;
    final type = EditorBackgroundType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => EditorBackgroundType.handwritingPaper,
    );
    final paperName = json['paperType'] as String?;
    return EditorBackground(
      type: type,
      color: _toColor(json['color'], const Color(0xFFFFFFFF)),
      imageBytes: json['imageBase64'] != null
          ? base64Decode(json['imageBase64'] as String)
          : null,
      imageName: json['imageName'] as String?,
      paperType: paperName == null
          ? HandwritingPaperType.ruled
          : HandwritingPaperType.values.firstWhere(
              (e) => e.name == paperName,
              orElse: () => HandwritingPaperType.ruled,
            ),
      paperColor: _toColor(json['paperColor'], const Color(0xFFFFFFFF)),
      paperLineColor: _toColor(json['paperLineColor'], const Color(0xFF8FB6E8)),
      paperLineSpacing: _toDouble(json['paperLineSpacing'], 58),
    );
  }

  static double _toDouble(dynamic v, double fallback) =>
      (v is num) ? v.toDouble() : fallback;
  static Color _toColor(dynamic v, Color fallback) =>
      (v is int) ? Color(v) : fallback;
}

/// 涂鸦笔画
class DoodleStroke {
  /// 归一化坐标点 (0~1, 相对涂鸦画布宽高), 便于缩放/旋转复用
  final List<OffsetN> points;

  /// 笔触颜色 (ARGB)
  final int colorArgb;

  /// 笔触宽度 (逻辑 px, 相对基准宽度)
  final double width;

  const DoodleStroke({
    required this.points,
    required this.colorArgb,
    required this.width,
  });

  DoodleStroke copyWith({
    List<OffsetN>? points,
    int? colorArgb,
    double? width,
  }) {
    return DoodleStroke(
      points: points ?? this.points,
      colorArgb: colorArgb ?? this.colorArgb,
      width: width ?? this.width,
    );
  }

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => [p.x, p.y]).toList(),
        'color': colorArgb,
        'width': width,
      };

  static DoodleStroke fromJson(Map<String, dynamic> json) {
    final raw = (json['points'] as List?) ?? [];
    final points = raw
        .map((e) {
          final pair = (e as List).cast<num>();
          return OffsetN(pair[0].toDouble(), pair[1].toDouble());
        })
        .toList();
    return DoodleStroke(
      points: points,
      colorArgb: (json['color'] as int?) ?? 0xFF1A1A1A,
      width: _toDouble(json['width'], 3),
    );
  }

  static double _toDouble(dynamic v, double fallback) =>
      (v is num) ? v.toDouble() : fallback;
}

/// 归一化坐标 (0~1)
class OffsetN {
  final double x;
  final double y;
  const OffsetN(this.x, this.y);
}

/// 编辑器组件类型
enum EditorComponentType {
  /// 文本
  text,

  /// 图片
  image,

  /// 公式 (LaTeX)
  formula,

  /// 涂鸦 (自由绘制)
  doodle,
}

/// 编辑器组件
///
/// 所有组件统一视为可移动/缩放/旋转的画布元素。
/// - [x]/[y]: 画布逻辑坐标 (左上角, px)
/// - [scale]: 统一缩放
/// - [rotation]: 旋转角度 (度)
/// - [width]/[height]: 基准尺寸 (逻辑 px)
class EditorComponent {
  final String id;
  final EditorComponentType type;
  final double x;
  final double y;
  final double width;
  final double height;
  final double scale;
  final double rotation;

  /// 文本 (type=text)
  final String? text;
  final double? textFontSize;
  final int? textColorArgb;

  /// 图片 (type=image)
  final Uint8List? imageBytes;
  final String? imageName;

  /// 公式 (type=formula)
  final String? latex;
  final double? formulaFontSize;

  /// 公式文本颜色 (ARGB, type=formula 有效; null 渲染为黑色)
  final int? formulaColorArgb;

  /// 涂鸦 (type=doodle)
  final EditorBackground? doodleBackground;
  final List<DoodleStroke>? doodleStrokes;

  EditorComponent({
    required this.id,
    required this.type,
    this.x = 40,
    this.y = 40,
    this.width = 240,
    this.height = 120,
    this.scale = 1,
    this.rotation = 0,
    this.text,
    this.textFontSize,
    this.textColorArgb,
    this.imageBytes,
    this.imageName,
    this.latex,
    this.formulaFontSize,
    this.formulaColorArgb,
    this.doodleBackground,
    this.doodleStrokes,
  });

  EditorComponent copyWith({
    String? id,
    double? x,
    double? y,
    double? width,
    double? height,
    double? scale,
    double? rotation,
    String? text,
    double? textFontSize,
    int? textColorArgb,
    Uint8List? imageBytes,
    String? imageName,
    bool clearImage = false,
    String? latex,
    double? formulaFontSize,
    int? formulaColorArgb,
    EditorBackground? doodleBackground,
    List<DoodleStroke>? doodleStrokes,
  }) {
    return EditorComponent(
      id: id ?? this.id,
      type: type,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      text: text ?? this.text,
      textFontSize: textFontSize ?? this.textFontSize,
      textColorArgb: textColorArgb ?? this.textColorArgb,
      imageBytes: clearImage ? null : (imageBytes ?? this.imageBytes),
      imageName: imageName ?? this.imageName,
      latex: latex ?? this.latex,
      formulaFontSize: formulaFontSize ?? this.formulaFontSize,
      formulaColorArgb: formulaColorArgb ?? this.formulaColorArgb,
      doodleBackground: doodleBackground ?? this.doodleBackground,
      doodleStrokes: doodleStrokes ?? this.doodleStrokes,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'scale': scale,
        'rotation': rotation,
        if (text != null) 'text': text,
        if (textFontSize != null) 'textFontSize': textFontSize,
        if (textColorArgb != null) 'textColor': textColorArgb,
        if (imageBytes != null) 'imageBase64': base64Encode(imageBytes!),
        if (imageName != null) 'imageName': imageName,
        if (latex != null) 'latex': latex,
        if (formulaFontSize != null) 'formulaFontSize': formulaFontSize,
        if (formulaColorArgb != null) 'formulaColor': formulaColorArgb,
        if (doodleBackground != null)
          'doodleBackground': doodleBackground!.toJson(),
        if (doodleStrokes != null)
          'doodleStrokes': doodleStrokes!.map((s) => s.toJson()).toList(),
      };

  static EditorComponent fromJson(Map<String, dynamic> json) {
    final type = EditorComponentType.values.firstWhere(
      (e) => e.name == (json['type'] as String?),
      orElse: () => EditorComponentType.text,
    );
    return EditorComponent(
      id: (json['id'] as String?) ?? _genId(),
      type: type,
      x: _toDouble(json['x'], 40),
      y: _toDouble(json['y'], 40),
      width: _toDouble(json['width'], 240),
      height: _toDouble(json['height'], 120),
      scale: _toDouble(json['scale'], 1),
      rotation: _toDouble(json['rotation'], 0),
      text: json['text'] as String?,
      textFontSize: _toDoubleOrNull(json['textFontSize']),
      textColorArgb: json['textColor'] as int?,
      imageBytes: json['imageBase64'] != null
          ? base64Decode(json['imageBase64'] as String)
          : null,
      imageName: json['imageName'] as String?,
      latex: json['latex'] as String?,
      formulaFontSize: _toDoubleOrNull(json['formulaFontSize']),
      formulaColorArgb: json['formulaColor'] as int?,
      doodleBackground: json['doodleBackground'] != null
          ? EditorBackground.fromJson(
              (json['doodleBackground'] as Map).cast<String, dynamic>())
          : null,
      doodleStrokes: (json['doodleStrokes'] as List?)
          ?.map((e) => DoodleStroke.fromJson(
              (e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  static String _genId() =>
      'c_${DateTime.now().microsecondsSinceEpoch}';

  static double _toDouble(dynamic v, double fallback) =>
      (v is num) ? v.toDouble() : fallback;
  static double? _toDoubleOrNull(dynamic v) => (v is num) ? v.toDouble() : null;
}

/// 编辑器配置 (整页)
class EditorConfig {
  /// 画布逻辑尺寸 (px, 导出按此尺寸渲染; 预览按比例缩放)
  final double canvasWidth;
  final double canvasHeight;

  /// 画布背景
  final EditorBackground background;

  /// 组件列表 (绘制顺序 = 数组顺序)
  final List<EditorComponent> components;

  const EditorConfig({
    this.canvasWidth = 1080,
    this.canvasHeight = 1528,
    this.background = const EditorBackground(),
    this.components = const [],
  });

  EditorConfig copyWith({
    double? canvasWidth,
    double? canvasHeight,
    EditorBackground? background,
    List<EditorComponent>? components,
  }) {
    return EditorConfig(
      canvasWidth: canvasWidth ?? this.canvasWidth,
      canvasHeight: canvasHeight ?? this.canvasHeight,
      background: background ?? this.background,
      components: components ?? this.components,
    );
  }

  /// 调整画布尺寸: 组件位置与尺寸按新旧宽高比例等比缩放, 保持相对布局
  ///
  /// 涂鸦笔画为组件内归一化坐标, 不受影响; 字号/线宽为绝对值, 保持不变。
  EditorConfig resized(double newWidth, double newHeight) {
    if (canvasWidth <= 0 || canvasHeight <= 0) {
      return copyWith(canvasWidth: newWidth, canvasHeight: newHeight);
    }
    final rx = newWidth / canvasWidth;
    final ry = newHeight / canvasHeight;
    return copyWith(
      canvasWidth: newWidth,
      canvasHeight: newHeight,
      components: components
          .map((c) => c.copyWith(
                x: c.x * rx,
                y: c.y * ry,
                width: c.width * rx,
                height: c.height * ry,
              ))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'canvasWidth': canvasWidth,
        'canvasHeight': canvasHeight,
        'background': background.toJson(),
        'components': components.map((c) => c.toJson()).toList(),
      };

  static EditorConfig fromJson(Map<String, dynamic> json) {
    return EditorConfig(
      canvasWidth: (json['canvasWidth'] as num?)?.toDouble() ?? 1080,
      canvasHeight: (json['canvasHeight'] as num?)?.toDouble() ?? 1528,
      background: json['background'] != null
          ? EditorBackground.fromJson(
              (json['background'] as Map).cast<String, dynamic>())
          : const EditorBackground(),
      components: (json['components'] as List?)
              ?.map((e) => EditorComponent.fromJson(
                  (e as Map).cast<String, dynamic>()))
              .toList() ??
          [],
    );
  }
}
