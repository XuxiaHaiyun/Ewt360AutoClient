/// 字体管理: 描述可选字体 (默认/系统/内置/导入), 提供字体文件导入
/// (复制到应用支持目录 + FontLoader 注册)、删除与运行时注册能力。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用字体条目
///
/// 统一描述"字体管理"中可选的字体: 默认主题字体 / 系统内置字体 /
/// 应用内置字体包 (pubspec 注册) / 用户导入的字体文件。
class AppFontOption {
  /// 字体来源类别: 'default' | 'system' | 'bundled' | 'imported'
  final String kind;

  /// 字体值: system = 系统字体族名; bundled = pubspec 注册的 family;
  /// imported = 导入时注册的 family (= 文件名去扩展)
  final String value;

  /// 显示名称
  final String label;

  /// 导入字体的文件路径 (仅 imported 有效)
  final String path;

  const AppFontOption({
    required this.kind,
    required this.value,
    required this.label,
    this.path = '',
  });

  /// 应用于 TextStyle.fontFamily 的字体族名 (default 返回 null = 跟随主题)
  String? get fontFamily => kind == 'default' ? null : value;
}

/// 导入字体的持久化条目 (family + 应用内副本路径)
class ImportedFont {
  final String family;
  final String path;

  const ImportedFont({required this.family, required this.path});

  ImportedFont.fromJson(Map<String, dynamic> json)
      : family = (json['family'] ?? '').toString(),
        path = (json['path'] ?? '').toString();

  Map<String, dynamic> toJson() => {'family': family, 'path': path};

  @override
  bool operator ==(Object other) =>
      other is ImportedFont && other.family == family && other.path == path;

  @override
  int get hashCode => Object.hash(family, path);
}

/// 字体管理服务
///
/// - 全局显示字体: 设置页选择后写入 settings, 经 AppTheme 注入 ThemeData;
/// - 导入字体: 文件复制到应用支持目录持久化, FontLoader 注册 family 后
///   立即可用 (全局显示 + 手写模拟自定义字体共用);
/// - 手写模拟: 导入的字体以 [ImportedFont.path] 提供给
///   HandwritingFontResolver (custom 来源, 按路径加载)。
class FontManager {
  FontManager._();

  /// 运行时已通过 FontLoader 注册的字体族
  static final Set<String> _loadedFamilies = {};

  /// 系统内置字体候选 (按平台可解析性整理; 不可解析时引擎回退默认字体,
  /// 不会报错): Windows 常见中文字体族名 + 跨平台通用族名
  static const List<AppFontOption> systemFonts = [
    AppFontOption(kind: 'system', value: 'sans-serif', label: '无衬线 (sans-serif)'),
    AppFontOption(kind: 'system', value: 'serif', label: '衬线 (serif)'),
    AppFontOption(kind: 'system', value: 'monospace', label: '等宽 (monospace)'),
    AppFontOption(kind: 'system', value: 'Microsoft YaHei', label: '微软雅黑'),
    AppFontOption(kind: 'system', value: 'SimSun', label: '宋体'),
    AppFontOption(kind: 'system', value: 'KaiTi', label: '楷体'),
    AppFontOption(kind: 'system', value: 'SimHei', label: '黑体'),
    AppFontOption(kind: 'system', value: 'Roboto', label: 'Roboto'),
  ];

  /// 导入字体文件 (ttf/otf/ttc), 复制到应用支持目录持久化并注册
  ///
  /// 返回导入结果 (null = 取消、文件非法或导入失败)。
  static Future<ImportedFont?> importFont() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['ttf', 'otf', 'ttc'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return null;
      final source = picked.files.single;
      final ext = p.extension(source.name).toLowerCase();
      if (!['.ttf', '.otf', '.ttc'].contains(ext)) return null;

      final bytes = await _readBytes(source);
      if (bytes == null || bytes.isEmpty) return null;

      final supportDir = await getApplicationSupportDirectory();
      final fontsDir = Directory(p.join(supportDir.path, 'fonts'));
      if (!await fontsDir.exists()) await fontsDir.create(recursive: true);

      // family = 文件名去扩展 (同名文件覆盖, 保证重复导入幂等)
      final family = p.basenameWithoutExtension(source.name);
      final targetPath = p.join(fontsDir.path, source.name);
      await File(targetPath).writeAsBytes(bytes, flush: true);

      final loaded = await registerFamily(family, targetPath);
      if (!loaded) {
        // 字体数据非法: 清理副本
        final target = File(targetPath);
        if (await target.exists()) await target.delete();
        return null;
      }
      return ImportedFont(family: family, path: targetPath);
    } catch (_) {
      return null;
    }
  }

  /// 删除导入字体的持久化副本
  static Future<void> deleteFontFile(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 注册字体族 (从文件字节); 已注册过直接返回 true
  ///
  /// 注册失败 (文件损坏/非字体) 返回 false。
  static Future<bool> registerFamily(String family, String path) async {
    if (_loadedFamilies.contains(family)) return true;
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return false;
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedFamilies.add(family);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Uint8List?> _readBytes(PlatformFile pickedFile) async {
    final data = pickedFile.bytes;
    if (data != null && data.isNotEmpty) return data;
    final path = pickedFile.path;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  }
}
