/// PDF 导出字体配置
///
/// 支持三种字体来源:
/// - [ExportFontType.bundled] 内置字体 (assets 中预置的 TTF, 如 HarmonyOS Sans SC)
/// - [ExportFontType.system] 系统字体 (从系统字体目录加载, 如 Windows simhei / Android NotoSansCJK)
/// - [ExportFontType.custom] 自定义 TTF 文件 (用户从文件系统选择的 .ttf 文件路径)
class ExportFontConfig {
  final ExportFontType type;

  /// 内置字体标识 (type=bundled 时有效)
  ///
  /// 可选值: 'harmonyos' (HarmonyOS Sans SC)
  final String bundledName;

  /// 自定义 TTF 文件绝对路径 (type=custom 时有效)
  final String customFontPath;

  const ExportFontConfig({
    this.type = ExportFontType.bundled,
    this.bundledName = 'harmonyos',
    this.customFontPath = '',
  });

  /// 默认配置: 内置 HarmonyOS Sans SC
  const ExportFontConfig.bundled()
      : type = ExportFontType.bundled,
        bundledName = 'harmonyos',
        customFontPath = '';

  /// 系统字体
  const ExportFontConfig.system()
      : type = ExportFontType.system,
        bundledName = '',
        customFontPath = '';

  /// 自定义 TTF 文件
  const ExportFontConfig.custom(String path)
      : type = ExportFontType.custom,
        bundledName = '',
        customFontPath = path;

  ExportFontConfig copyWith({
    ExportFontType? type,
    String? bundledName,
    String? customFontPath,
  }) {
    return ExportFontConfig(
      type: type ?? this.type,
      bundledName: bundledName ?? this.bundledName,
      customFontPath: customFontPath ?? this.customFontPath,
    );
  }

  @override
  String toString() {
    return switch (type) {
      ExportFontType.bundled => '内置字体($bundledName)',
      ExportFontType.system => '系统字体',
      ExportFontType.custom => '自定义字体($customFontPath)',
    };
  }
}

/// 字体来源类型
enum ExportFontType {
  /// 内置字体 (assets 中预置)
  bundled,

  /// 系统字体 (从系统字体目录加载)
  system,

  /// 自定义 TTF 文件 (用户选择)
  custom,
}

/// 内置字体选项
class BundledFontOption {
  final String name;
  final String label;
  final String assetPath;
  final String? boldAssetPath;

  const BundledFontOption({
    required this.name,
    required this.label,
    required this.assetPath,
    this.boldAssetPath,
  });

  static const harmonyos = BundledFontOption(
    name: 'harmonyos',
    label: 'HarmonyOS Sans SC (鸿蒙黑体)',
    assetPath: 'assets/fonts/HarmonyOS_Sans_SC_Regular.ttf',
    boldAssetPath: 'assets/fonts/HarmonyOS_Sans_SC_Bold.ttf',
  );

  /// 所有内置字体选项
  static const all = [harmonyos];
}
