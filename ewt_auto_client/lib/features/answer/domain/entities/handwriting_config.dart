/// 手写模拟配置实体：字体、倾斜/起伏/弯曲等笔画级参数、涂改、纸张背景及 JSON 序列化。
/// 所有随机量基于 randomSeed，同一配置渲染结果可复现；反序列化对非法字段容错回退默认值。
library;

import 'dart:ui' show Color;

/// 手写模拟配置
///
/// 用于"根据答案/解析生成图片"时把答案/解析内容渲染成接近真实手写的图片:
/// - 自定义手写字体 (内置 6 款 OFL 开源中文字体 / 系统字体 / 自定义 TTF)
/// - 笔画级模拟: 逐字倾斜、基线起伏、行弯曲、字号/笔压随机变化
/// - 涂改 (划线修正), 背景纸张 (空白/横线/方格/田字格, 可调线距/线色/纸色)
/// - 公式与图片模拟手绘 (轻微旋转/扭曲)
///
/// 所有随机量基于 [randomSeed], 同一配置每次生成结果一致。
class HandwritingConfig {
  /// 字体配置
  final HandwritingFontConfig font;

  /// 基准字号 (px, 输出图按 [scale] 换算)
  final double fontSize;

  /// 字号变化幅度 (0~1, 相对基准字号的随机比例)
  final double fontSizeJitter;

  /// 整体倾斜角度 (度, 正=右倾)
  final double tiltAngle;

  /// 倾斜随机变化幅度 (度)
  final double tiltJitter;

  /// 行内基线起伏幅度 (px, 每个字在基线上下随机浮动)
  final double baselineJitter;

  /// 行弯曲幅度 (px, 整行按正弦曲线弯曲, 模拟手写走线)
  final double lineWaviness;

  /// 行距 (相对字号的倍数)
  final double lineHeight;

  /// 字间距 (px)
  final double letterSpacing;

  /// 词间距 (px, 拉丁单词/数字之间)
  final double wordSpacing;

  /// 笔画粗细 (0.5~2.5, 1.0 为标准)
  ///
  /// 实现: 通过多次微偏移叠加绘制模拟笔压加粗, 同时影响单字尺寸。
  final double strokeWidth;

  /// 笔压变化幅度 (0~1, 单字墨色浓度随机变化)
  final double pressureJitter;

  /// 墨迹颜色
  final Color inkColor;

  /// 纸张类型
  final HandwritingPaperType paperType;

  /// 纸张颜色
  final Color paperColor;

  /// 纸张线条颜色 (横线/方格/田字格)
  final Color paperLineColor;

  /// 纸张线条间距 (px, 横线/方格/田字格的单元高度, 可手动调整)
  final double paperLineSpacing;

  /// 页边距 (px)
  final double margin;

  /// 是否启用涂改 (在随机位置模拟划线修正)
  final bool scratchOut;

  /// 涂改样式
  final ScratchOutStyle scratchOutStyle;

  /// 涂改次数 (整页最多划线处数)
  final int scratchOutCount;

  /// 涂改线颜色
  final Color scratchOutColor;

  /// 图片/公式弯曲度 (0~1, 控制内嵌图片的旋转/扭曲幅度)
  final double imageCurvature;

  /// 随机种子 (保证同一配置渲染结果可复现)
  final int randomSeed;

  /// 输出缩放 (字号等像素参数按此比例换算, 预览用 0.5 等)
  final double scale;

  const HandwritingConfig({
    this.font = const HandwritingFontConfig.bundled(),
    this.fontSize = 34,
    this.fontSizeJitter = 0.06,
    this.tiltAngle = 2,
    this.tiltJitter = 1.2,
    this.baselineJitter = 3,
    this.lineWaviness = 4,
    this.lineHeight = 1.8,
    this.letterSpacing = 1.0,
    this.wordSpacing = 10,
    this.strokeWidth = 1.0,
    this.pressureJitter = 0.15,
    this.inkColor = const Color(0xFF1A1A1A),
    this.paperType = HandwritingPaperType.ruled,
    this.paperColor = const Color(0xFFFFFFFF),
    this.paperLineColor = const Color(0xFF8FB6E8),
    this.paperLineSpacing = 58,
    this.margin = 48,
    this.scratchOut = false,
    this.scratchOutStyle = ScratchOutStyle.singleLine,
    this.scratchOutCount = 1,
    this.scratchOutColor = const Color(0xFFC62828),
    this.imageCurvature = 0.2,
    this.randomSeed = 42,
    this.scale = 1.0,
  });

  /// 关闭手写模拟 (走原有 HTML 渲染)
  static const disabled = HandwritingConfig();

  HandwritingConfig copyWith({
    HandwritingFontConfig? font,
    double? fontSize,
    double? fontSizeJitter,
    double? tiltAngle,
    double? tiltJitter,
    double? baselineJitter,
    double? lineWaviness,
    double? lineHeight,
    double? letterSpacing,
    double? wordSpacing,
    double? strokeWidth,
    double? pressureJitter,
    Color? inkColor,
    HandwritingPaperType? paperType,
    Color? paperColor,
    Color? paperLineColor,
    double? paperLineSpacing,
    double? margin,
    bool? scratchOut,
    ScratchOutStyle? scratchOutStyle,
    int? scratchOutCount,
    Color? scratchOutColor,
    double? imageCurvature,
    int? randomSeed,
    double? scale,
  }) {
    return HandwritingConfig(
      font: font ?? this.font,
      fontSize: fontSize ?? this.fontSize,
      fontSizeJitter: fontSizeJitter ?? this.fontSizeJitter,
      tiltAngle: tiltAngle ?? this.tiltAngle,
      tiltJitter: tiltJitter ?? this.tiltJitter,
      baselineJitter: baselineJitter ?? this.baselineJitter,
      lineWaviness: lineWaviness ?? this.lineWaviness,
      lineHeight: lineHeight ?? this.lineHeight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      wordSpacing: wordSpacing ?? this.wordSpacing,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      pressureJitter: pressureJitter ?? this.pressureJitter,
      inkColor: inkColor ?? this.inkColor,
      paperType: paperType ?? this.paperType,
      paperColor: paperColor ?? this.paperColor,
      paperLineColor: paperLineColor ?? this.paperLineColor,
      paperLineSpacing: paperLineSpacing ?? this.paperLineSpacing,
      margin: margin ?? this.margin,
      scratchOut: scratchOut ?? this.scratchOut,
      scratchOutStyle: scratchOutStyle ?? this.scratchOutStyle,
      scratchOutCount: scratchOutCount ?? this.scratchOutCount,
      scratchOutColor: scratchOutColor ?? this.scratchOutColor,
      imageCurvature: imageCurvature ?? this.imageCurvature,
      randomSeed: randomSeed ?? this.randomSeed,
      scale: scale ?? this.scale,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is HandwritingConfig &&
        other.font == font &&
        other.fontSize == fontSize &&
        other.fontSizeJitter == fontSizeJitter &&
        other.tiltAngle == tiltAngle &&
        other.tiltJitter == tiltJitter &&
        other.baselineJitter == baselineJitter &&
        other.lineWaviness == lineWaviness &&
        other.lineHeight == lineHeight &&
        other.letterSpacing == letterSpacing &&
        other.wordSpacing == wordSpacing &&
        other.strokeWidth == strokeWidth &&
        other.pressureJitter == pressureJitter &&
        other.inkColor == inkColor &&
        other.paperType == paperType &&
        other.paperColor == paperColor &&
        other.paperLineColor == paperLineColor &&
        other.paperLineSpacing == paperLineSpacing &&
        other.margin == margin &&
        other.scratchOut == scratchOut &&
        other.scratchOutStyle == scratchOutStyle &&
        other.scratchOutCount == scratchOutCount &&
        other.scratchOutColor == scratchOutColor &&
        other.imageCurvature == imageCurvature &&
        other.randomSeed == randomSeed &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hashAll([
        font,
        fontSize,
        fontSizeJitter,
        tiltAngle,
        tiltJitter,
        baselineJitter,
        lineWaviness,
        lineHeight,
        letterSpacing,
        wordSpacing,
        strokeWidth,
        pressureJitter,
        inkColor,
        paperType,
        paperColor,
        paperLineColor,
        paperLineSpacing,
        margin,
        scratchOut,
        scratchOutStyle,
        scratchOutCount,
        scratchOutColor,
        imageCurvature,
        randomSeed,
        scale,
      ]);

  /// 序列化为 JSON (用于持久化到 shared_preferences)
  Map<String, dynamic> toJson() => {
        'font': font.toJson(),
        'fontSize': fontSize,
        'fontSizeJitter': fontSizeJitter,
        'tiltAngle': tiltAngle,
        'tiltJitter': tiltJitter,
        'baselineJitter': baselineJitter,
        'lineWaviness': lineWaviness,
        'lineHeight': lineHeight,
        'letterSpacing': letterSpacing,
        'wordSpacing': wordSpacing,
        'strokeWidth': strokeWidth,
        'pressureJitter': pressureJitter,
        'inkColor': inkColor.toARGB32(),
        'paperType': paperType.name,
        'paperColor': paperColor.toARGB32(),
        'paperLineColor': paperLineColor.toARGB32(),
        'paperLineSpacing': paperLineSpacing,
        'margin': margin,
        'scratchOut': scratchOut,
        'scratchOutStyle': scratchOutStyle.name,
        'scratchOutCount': scratchOutCount,
        'scratchOutColor': scratchOutColor.toARGB32(),
        'imageCurvature': imageCurvature,
        'randomSeed': randomSeed,
        'scale': scale,
      };

  /// 从 JSON 反序列化 (容错: 缺少/非法字段回退到默认值)
  static HandwritingConfig fromJson(Map<String, dynamic> json) {
    final paperName = json['paperType'] as String?;
    final scratchName = json['scratchOutStyle'] as String?;
    return HandwritingConfig(
      font: HandwritingFontConfig.fromJson(
        (json['font'] as Map<String, dynamic>?) ?? {},
      ),
      fontSize: _toDouble(json['fontSize'], 34),
      fontSizeJitter: _toDouble(json['fontSizeJitter'], 0.06),
      tiltAngle: _toDouble(json['tiltAngle'], 2),
      tiltJitter: _toDouble(json['tiltJitter'], 1.2),
      baselineJitter: _toDouble(json['baselineJitter'], 3),
      lineWaviness: _toDouble(json['lineWaviness'], 4),
      lineHeight: _toDouble(json['lineHeight'], 1.8),
      letterSpacing: _toDouble(json['letterSpacing'], 1.0),
      wordSpacing: _toDouble(json['wordSpacing'], 10),
      strokeWidth: _toDouble(json['strokeWidth'], 1.0),
      pressureJitter: _toDouble(json['pressureJitter'], 0.15),
      inkColor: _toColor(json['inkColor'], const Color(0xFF1A1A1A)),
      paperType: paperName == null
          ? HandwritingPaperType.ruled
          : HandwritingPaperType.values.firstWhere(
              (e) => e.name == paperName,
              orElse: () => HandwritingPaperType.ruled,
            ),
      paperColor: _toColor(json['paperColor'], const Color(0xFFFFFFFF)),
      paperLineColor:
          _toColor(json['paperLineColor'], const Color(0xFF8FB6E8)),
      paperLineSpacing: _toDouble(json['paperLineSpacing'], 58),
      margin: _toDouble(json['margin'], 48),
      scratchOut: (json['scratchOut'] as bool?) ?? false,
      scratchOutStyle: scratchName == null
          ? ScratchOutStyle.singleLine
          : ScratchOutStyle.values.firstWhere(
              (e) => e.name == scratchName,
              orElse: () => ScratchOutStyle.singleLine,
            ),
      scratchOutCount: (json['scratchOutCount'] as int?) ?? 1,
      scratchOutColor: _toColor(json['scratchOutColor'], const Color(0xFFC62828)),
      imageCurvature: _toDouble(json['imageCurvature'], 0.2),
      randomSeed: (json['randomSeed'] as int?) ?? 42,
      scale: _toDouble(json['scale'], 1.0),
    );
  }

  /// 安全转 double
  static double _toDouble(dynamic v, double fallback) =>
      (v is num) ? v.toDouble() : fallback;

  /// 安全转 Color (ARGB 整数)
  static Color _toColor(dynamic v, Color fallback) =>
      (v is int) ? Color(v) : fallback;
}

/// 手写字体配置
class HandwritingFontConfig {
  final HandwritingFontSource source;

  /// 内置字体标识 (source=bundled 时有效, 对应 [HandwrittenFontOption.name])
  final String bundledName;

  /// 自定义 TTF 文件路径 (source=custom 时有效)
  final String customPath;

  const HandwritingFontConfig({
    this.source = HandwritingFontSource.bundled,
    this.bundledName = 'lxgw_wenkai',
    this.customPath = '',
  });

  const HandwritingFontConfig.bundled([this.bundledName = 'lxgw_wenkai'])
      : source = HandwritingFontSource.bundled,
        customPath = '';

  const HandwritingFontConfig.system()
      : source = HandwritingFontSource.system,
        bundledName = '',
        customPath = '';

  const HandwritingFontConfig.custom(String path)
      : source = HandwritingFontSource.custom,
        bundledName = '',
        customPath = path;

  HandwritingFontConfig copyWith({
    HandwritingFontSource? source,
    String? bundledName,
    String? customPath,
  }) {
    return HandwritingFontConfig(
      source: source ?? this.source,
      bundledName: bundledName ?? this.bundledName,
      customPath: customPath ?? this.customPath,
    );
  }

  /// 显示标签
  String get label {
    switch (source) {
      case HandwritingFontSource.bundled:
        final opt = HandwrittenFontOption.byName(bundledName);
        return opt?.label ?? '内置字体';
      case HandwritingFontSource.system:
        return '系统字体';
      case HandwritingFontSource.custom:
        return customPath.isEmpty ? '自定义字体' : customPath;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is HandwritingFontConfig &&
        other.source == source &&
        other.bundledName == bundledName &&
        other.customPath == customPath;
  }

  @override
  int get hashCode => Object.hash(source, bundledName, customPath);

  /// 序列化 (用于持久化)
  Map<String, dynamic> toJson() => {
        'source': source.name,
        'bundledName': bundledName,
        'customPath': customPath,
      };

  /// 反序列化 (容错: 缺少字段时使用默认值)
  static HandwritingFontConfig fromJson(Map<String, dynamic> json) {
    final sourceName = json['source'] as String? ?? 'bundled';
    final source = HandwritingFontSource.values.firstWhere(
      (e) => e.name == sourceName,
      orElse: () => HandwritingFontSource.bundled,
    );
    return HandwritingFontConfig(
      source: source,
      bundledName: (json['bundledName'] as String?) ?? 'lxgw_wenkai',
      customPath: (json['customPath'] as String?) ?? '',
    );
  }
}

/// 手写字体来源
enum HandwritingFontSource {
  /// 内置字体 (assets/fonts 中预置的 OFL 中文手写字体)
  bundled,

  /// 系统字体 (如 Windows 楷体 KaiTi)
  system,

  /// 自定义 TTF 文件
  custom,
}

/// 内置手写字体选项
class HandwrittenFontOption {
  final String name;
  final String label;
  final String assetPath;
  final String fontFamily;

  const HandwrittenFontOption({
    required this.name,
    required this.label,
    required this.assetPath,
    required this.fontFamily,
  });

  /// 霞鹜文楷 (楷书, 最接近日常手写, 推荐)
  static const lxgwWenKai = HandwrittenFontOption(
    name: 'lxgw_wenkai',
    label: '霞鹜文楷 (LXGW WenKai)',
    assetPath: 'assets/fonts/LXGWWenKai-Regular.ttf',
    fontFamily: 'LXGWWenKai',
  );

  /// 马善政毛笔 (毛笔楷书)
  static const maShanZheng = HandwrittenFontOption(
    name: 'ma_shan_zheng',
    label: '马善政毛笔 (Ma Shan Zheng)',
    assetPath: 'assets/fonts/MaShanZheng-Regular.ttf',
    fontFamily: 'MaShanZheng',
  );

  /// 龙藏行书 (行书手写)
  static const longCang = HandwrittenFontOption(
    name: 'long_cang',
    label: '龙藏行书 (Long Cang)',
    assetPath: 'assets/fonts/LongCang-Regular.ttf',
    fontFamily: 'LongCang',
  );

  /// 站酷快乐体 (手写卡通)
  static const zcoolKuaiLe = HandwrittenFontOption(
    name: 'zcool_kuaile',
    label: '站酷快乐体 (ZCOOL KuaiLe)',
    assetPath: 'assets/fonts/ZCOOLKuaiLe-Regular.ttf',
    fontFamily: 'ZCOOLKuaiLe',
  );

  /// 之芒星行草 (行草)
  static const zhiMangXing = HandwrittenFontOption(
    name: 'zhi_mang_xing',
    label: '之芒星行草 (Zhi Mang Xing)',
    assetPath: 'assets/fonts/ZhiMangXing-Regular.ttf',
    fontFamily: 'ZhiMangXing',
  );

  /// 刘建猫草 (草书)
  static const liuJianMaoCao = HandwrittenFontOption(
    name: 'liu_jian_mao_cao',
    label: '刘建猫草 (Liu Jian Mao Cao)',
    assetPath: 'assets/fonts/LiuJianMaoCao-Regular.ttf',
    fontFamily: 'LiuJianMaoCao',
  );

  /// 寒蝉手拙体 (手写拙体)
  static const hanchanShouzhuo = HandwrittenFontOption(
    name: 'hanchan_shouzhuo',
    label: '寒蝉手拙体',
    assetPath: 'assets/fonts/HanchanShouzhuo-Regular.ttf',
    fontFamily: 'HanchanShouzhuo',
  );

  /// 新叶念体 (楷书手写)
  static const xinyeNianti = HandwrittenFontOption(
    name: 'xinye_nianti',
    label: '新叶念体',
    assetPath: 'assets/fonts/XinyeNianti-Regular.otf',
    fontFamily: 'XinyeNianti',
  );

  /// 栗壳坚坚体 (卡通手写)
  static const likeJianJian = HandwrittenFontOption(
    name: 'like_jian_jian',
    label: '栗壳坚坚体',
    assetPath: 'assets/fonts/LikeJianJian-Regular.ttf',
    fontFamily: 'LikeJianJian',
  );

  /// 江西拙楷 (拙楷)
  static const jiangxiZhuokai = HandwrittenFontOption(
    name: 'jiangxi_zhuokai',
    label: '江西拙楷',
    assetPath: 'assets/fonts/JiangxiZhuokai-Regular.ttf',
    fontFamily: 'JiangxiZhuokai',
  );

  /// 沐瑶随心手写体 (随性手写)
  static const muyaoSuixin = HandwrittenFontOption(
    name: 'muyao_suixin',
    label: '沐瑶随心手写体',
    assetPath: 'assets/fonts/MuyaoSuixin-Regular.ttf',
    fontFamily: 'MuyaoSuixin',
  );

  /// 油茶馓子体 (圆润手写)
  static const youchazhi = HandwrittenFontOption(
    name: 'youchazhi',
    label: '油茶馓子体',
    assetPath: 'assets/fonts/Youchazhi-Regular.ttf',
    fontFamily: 'Youchazhi',
  );

  /// 白路彤彤手写体 (学生手写)
  static const bailuTongtong = HandwrittenFontOption(
    name: 'bailu_tongtong',
    label: '白路彤彤手写体',
    assetPath: 'assets/fonts/BailuTongtong-Regular.ttf',
    fontFamily: 'BailuTongtong',
  );

  /// 随峰体Plus (手写连笔)
  static const suifengPlus = HandwrittenFontOption(
    name: 'suifeng_plus',
    label: '随峰体Plus',
    assetPath: 'assets/fonts/SuifengPlus-Regular.ttf',
    fontFamily: 'SuifengPlus',
  );

  /// 所有内置字体选项
  static const all = [
    lxgwWenKai,
    maShanZheng,
    longCang,
    zcoolKuaiLe,
    zhiMangXing,
    liuJianMaoCao,
    hanchanShouzhuo,
    xinyeNianti,
    likeJianJian,
    jiangxiZhuokai,
    muyaoSuixin,
    youchazhi,
    bailuTongtong,
    suifengPlus,
  ];

  /// 按 name 查找
  static HandwrittenFontOption? byName(String name) {
    for (final o in all) {
      if (o.name == name) return o;
    }
    return null;
  }
}

/// 纸张类型
enum HandwritingPaperType {
  /// 空白纸
  blank,

  /// 横线纸
  ruled,

  /// 方格纸
  grid,

  /// 田字格
  tianzige,
}

/// 涂改样式
enum ScratchOutStyle {
  /// 单横线
  singleLine,

  /// 双横线
  doubleLine,

  /// 波浪线
  wave,

  /// 涂黑 (用涂改色覆盖整块区域)
  blackOut,
}
