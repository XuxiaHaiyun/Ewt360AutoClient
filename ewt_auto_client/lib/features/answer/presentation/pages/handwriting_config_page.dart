/// 手写模拟配置页，可视化配置全部手写参数（字体/笔迹/排版/纸张/涂改）并带实时预览，宽屏双栏、窄屏堆叠。
/// 路由 `/handwriting-config`，经 GoRouter extra 传入初始配置；配置经 handwritingConfigProvider 持久化。
library;

import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/handwriting_config.dart';
import '../providers/handwriting_config_provider.dart';
import '../widgets/handwritten_page.dart' show HandwrittenPage;
import '../../../../core/fonts/font_manager.dart' show ImportedFont;
import '../../../../features/settings/presentation/providers/settings_provider.dart';

/// 手写模拟配置页 (独立页面, 非弹窗)
///
/// 替代原 [HandwritingConfigDialog], 提供:
/// - 全部手写模拟参数可视化配置 (字体/笔迹/姿态/排版/纸张/涂改/其他)
/// - 顶部实时预览区随参数变化即时刷新
/// - 响应式布局: 宽屏左右双栏 (预览 | 配置), 窄屏上下堆叠
/// - 配置可持久化: 通过 [handwritingConfigProvider] 写入 shared_preferences,
///   下次打开自动恢复; "保存"返回最新配置给调用方。
///
/// 路由: `/handwriting-config` (name: 'handwriting-config')
/// 通过 GoRouter 的 `extra` 传入当前 [HandwritingConfig] 作为初始值 (可为 null)。
class HandwritingConfigPage extends ConsumerStatefulWidget {
  /// 初始配置 (来自调用方, 如生成图片方案中的当前手写配置)
  final HandwritingConfig? initial;

  const HandwritingConfigPage({super.key, this.initial});

  @override
  ConsumerState<HandwritingConfigPage> createState() =>
      _HandwritingConfigPageState();
}

class _HandwritingConfigPageState extends ConsumerState<HandwritingConfigPage> {
  late HandwritingConfig _config;
  late final TextEditingController _seedCtrl;

  /// 最近一次自定义的纸张颜色 (用于再次打开取色器时的初始值)
  late Color _customPaperColor;

  /// 预览样例 (含中文/拉丁/数字/符号)
  static const _sampleHtml =
      '解：设函数 f(x) = 2x³ − 3x² + 1，则 f′(x) = 6x² − 6x。'
      '令 f′(x) = 0，得 x₁ = 0，x₂ = 1。经检验，f(x) 在 [0, 1] 上单调递减，'
      '故最大值为 f(0) = 1，答案见解析。';

  static const _inkPresets = [
    Color(0xFF1D3F8F), // 蓝黑
    Color(0xFF1A1A1A), // 黑
    Color(0xFF1E5AA8), // 蓝
    Color(0xFFB03030), // 红
    Color(0xFF6B6B6B), // 灰
  ];

  static const _paperPresets = [
    Color(0xFFFFFFFF), // 白
    Color(0xFFFFF8E7), // 米黄
    Color(0xFFEAF4FF), // 浅蓝
    Color(0xFFF0F9F0), // 浅绿
  ];

  static const _linePresets = [
    Color(0xFF8FB6E8), // 浅蓝
    Color(0xFFBDBDBD), // 灰
    Color(0xFFA5C89A), // 绿
    Color(0xFFE8A9A0), // 红
  ];

  @override
  void initState() {
    super.initState();
    // 优先使用调用方传入的配置; 否则使用已持久化的默认配置
    _config = widget.initial ?? ref.read(handwritingConfigProvider);
    _seedCtrl = TextEditingController(text: '${_config.randomSeed}');
    // 若初始纸色非预设, 则视作自定义色
    _customPaperColor = _isCustomPaper ? _config.paperColor : const Color(0xFFFFE0B2);
  }

  @override
  void dispose() {
    _seedCtrl.dispose();
    super.dispose();
  }

  void _update(HandwritingConfig c) => setState(() => _config = c);

  void _applySeed() {
    final v = int.tryParse(_seedCtrl.text.trim());
    if (v != null) _update(_config.copyWith(randomSeed: v));
  }

  /// 当前纸色是否不属于预设 (即"自定义")
  bool get _isCustomPaper =>
      !_paperPresets.any((c) => c.toARGB32() == _config.paperColor.toARGB32());

  /// 保存: 持久化 + 返回配置给调用方
  void _save() {
    ref.read(handwritingConfigProvider.notifier).save(_config);
    Navigator.of(context).pop(_config);
  }

  /// 恢复默认 (仅本地, 需点击保存才持久化)
  void _reset() => setState(() => _config = const HandwritingConfig());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回 (不保存)',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('手写模拟配置'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.restart_alt_outlined, size: 18),
            label: const Text('恢复默认'),
            onPressed: _reset,
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存'),
            onPressed: _save,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 720;
          final preview = _buildPreview(theme, isWide: isWide);
          final controls = _buildControls(theme);
          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(color: theme.dividerColor),
                      ),
                    ),
                    child: preview,
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: controls,
                    ),
                  ),
                ),
              ],
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                preview,
                const SizedBox(height: 12),
                controls,
              ],
            ),
          );
        },
      ),
    );
  }

  // ─── 实时预览 ───

  Widget _buildPreview(ThemeData theme, {required bool isWide}) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = max(280.0, c.maxWidth);
        return Container(
          height: isWide ? double.infinity : 240,
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.4),
          padding: const EdgeInsets.all(8),
          child: ClipRect(
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: IgnorePointer(
                  child: HandwrittenPage(
                    key: ValueKey(_config),
                    html: _sampleHtml,
                    config: _config.copyWith(scale: isWide ? 0.7 : 0.6),
                    width: w,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ─── 配置区 ───

  Widget _buildControls(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFontSection(theme),
        const Divider(height: 20),
        _buildInkSection(theme),
        const Divider(height: 20),
        _buildPoseSection(theme),
        const Divider(height: 20),
        _buildLayoutSection(theme),
        const Divider(height: 20),
        _buildPaperSection(theme),
        const Divider(height: 20),
        _buildScratchSection(theme),
        const Divider(height: 20),
        _buildMiscSection(theme),
      ],
    );
  }

  // ─── 字体 ───

  Widget _buildFontSection(ThemeData theme) {
    final font = _config.font;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '手写字体'),
        RadioGroup<HandwritingFontSource>(
          groupValue: font.source,
          onChanged: (v) {
            if (v != null) {
              _update(_config.copyWith(font: _config.font.copyWith(source: v)));
            }
          },
          child: Wrap(
            spacing: 4,
            runSpacing: -8,
            children: [
              for (final src in HandwritingFontSource.values)
                _fontSourceTile(theme, src),
            ],
          ),
        ),
        if (font.source == HandwritingFontSource.bundled)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DropdownButtonFormField<String>(
              initialValue: font.bundledName,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              items: HandwrittenFontOption.all
                  .map((o) => DropdownMenuItem(
                        value: o.name,
                        child:
                            Text(o.label, style: const TextStyle(fontSize: 13)),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  _update(_config.copyWith(
                      font: font.copyWith(bundledName: v)));
                }
              },
            ),
          ),
        if (font.source == HandwritingFontSource.custom)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.font_download_outlined, size: 18),
                      label: const Text('选择 TTF 字体文件'),
                      onPressed: _pickCustomFont,
                    ),
                    if (font.customPath.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          font.customPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ),
                // 设置页"字体管理"中导入的字体可直接选用 (按路径加载)
                if (_importedFonts(ref).isNotEmpty) ...[
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: font.customPath,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: '字体管理中导入的字体',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    items: [
                      for (final f in _importedFonts(ref))
                        DropdownMenuItem(
                          value: f.path,
                          child: Text(f.family,
                              style: const TextStyle(fontSize: 13)),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        _update(_config.copyWith(
                            font: font.copyWith(customPath: v)));
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        if (font.source == HandwritingFontSource.system)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '使用系统楷体 (Windows: 楷体 / Android: Noto Serif CJK SC)',
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _fontSourceTile(
    ThemeData theme,
    HandwritingFontSource src,
  ) {
    return SizedBox(
      width: 130,
      child: RadioListTile<HandwritingFontSource>(
        title: Text(
          switch (src) {
            HandwritingFontSource.bundled => '内置',
            HandwritingFontSource.system => '系统',
            HandwritingFontSource.custom => '自定义 TTF',
          },
          style: const TextStyle(fontSize: 13),
        ),
        value: src,
        dense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  /// 设置页"字体管理"导入的字体列表 (与全局显示字体共用)
  List<ImportedFont> _importedFonts(WidgetRef ref) =>
      ref.watch(appSettingsProvider).importedFonts;

  Future<void> _pickCustomFont() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
      withData: false,
    );
    if (result != null && result.files.single.path != null) {
      _update(_config.copyWith(
          font: _config.font.copyWith(
              source: HandwritingFontSource.custom,
              customPath: result.files.single.path!)));
    }
  }

  // ─── 笔迹 ───

  Widget _buildInkSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '笔迹'),
        Row(
          children: [
            Text('颜色', style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            for (final c in _inkPresets)
              _colorDot(c, _config.inkColor, (v) {
                _update(_config.copyWith(inkColor: v));
              }),
          ],
        ),
        _slider('字号', _config.fontSize, 12, 96, null,
            (v) => _update(_config.copyWith(fontSize: v)), (v) => '${v.round()}'),
        _slider('字号变化', _config.fontSizeJitter, 0, 0.3, 60,
            (v) => _update(_config.copyWith(fontSizeJitter: v)),
            (v) => '${(v * 100).round()}%'),
        _slider('笔画粗细', _config.strokeWidth, 0.5, 2.5, 40,
            (v) => _update(_config.copyWith(strokeWidth: v)),
            (v) => v.toStringAsFixed(1)),
        _slider('笔压变化', _config.pressureJitter, 0, 0.5, 50,
            (v) => _update(_config.copyWith(pressureJitter: v)),
            (v) => '${(v * 100).round()}%'),
      ],
    );
  }

  // ─── 姿态 ───

  Widget _buildPoseSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '书写姿态'),
        _slider('整体倾斜', _config.tiltAngle, -15, 15, 60,
            (v) => _update(_config.copyWith(tiltAngle: v)),
            (v) => '${v.toStringAsFixed(1)}°'),
        _slider('倾斜变化', _config.tiltJitter, 0, 5, 50,
            (v) => _update(_config.copyWith(tiltJitter: v)),
            (v) => '±${v.toStringAsFixed(1)}°'),
        _slider('基线起伏', _config.baselineJitter, 0, 12, 24,
            (v) => _update(_config.copyWith(baselineJitter: v)),
            (v) => '${v.toStringAsFixed(1)}px'),
        _slider('行弯曲度', _config.lineWaviness, 0, 15, 30,
            (v) => _update(_config.copyWith(lineWaviness: v)),
            (v) => '${v.toStringAsFixed(1)}px'),
      ],
    );
  }

  // ─── 排版 ───

  Widget _buildLayoutSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '排版间距'),
        _slider('行距 (字号倍数)', _config.lineHeight, 1.2, 3.0, 36,
            (v) => _update(_config.copyWith(lineHeight: v)),
            (v) => v.toStringAsFixed(1)),
        _slider('字间距', _config.letterSpacing, 0, 12, 24,
            (v) => _update(_config.copyWith(letterSpacing: v)),
            (v) => '${v.toStringAsFixed(1)}px'),
        _slider('词间距', _config.wordSpacing, 2, 24, 22,
            (v) => _update(_config.copyWith(wordSpacing: v)),
            (v) => '${v.round()}px'),
      ],
    );
  }

  // ─── 背景 ───

  Widget _buildPaperSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '纸张背景'),
        Wrap(
          spacing: 4,
          children: [
            _segmented<HandwritingPaperType>(
              HandwritingPaperType.blank, '空白', _config.paperType,
              (v) => _update(_config.copyWith(paperType: v)),
            ),
            _segmented<HandwritingPaperType>(
              HandwritingPaperType.ruled, '横线', _config.paperType,
              (v) => _update(_config.copyWith(paperType: v)),
            ),
            _segmented<HandwritingPaperType>(
              HandwritingPaperType.grid, '方格', _config.paperType,
              (v) => _update(_config.copyWith(paperType: v)),
            ),
            _segmented<HandwritingPaperType>(
              HandwritingPaperType.tianzige, '田字格', _config.paperType,
              (v) => _update(_config.copyWith(paperType: v)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            Text('纸色', style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            for (final c in _paperPresets)
              _colorDot(c, _config.paperColor, (v) {
                _update(_config.copyWith(paperColor: v));
              }),
            _customPaperChip(),
            const SizedBox(width: 16),
            Text('线色', style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            for (final c in _linePresets)
              _colorDot(c, _config.paperLineColor, (v) {
                _update(_config.copyWith(paperLineColor: v));
              }),
          ],
        ),
        _slider('线条间距', _config.paperLineSpacing, 24, 100, 76,
            (v) => _update(_config.copyWith(paperLineSpacing: v)),
            (v) => '${v.round()}px'),
        _slider('页边距', _config.margin, 20, 80, 60,
            (v) => _update(_config.copyWith(margin: v)),
            (v) => '${v.round()}px'),
      ],
    );
  }

  // ─── 涂改 ───

  Widget _buildScratchSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle(theme, '涂改 (划线修正)'),
            const Spacer(),
            Switch(
              value: _config.scratchOut,
              onChanged: (v) => _update(_config.copyWith(scratchOut: v)),
            ),
          ],
        ),
        if (_config.scratchOut) ...[
          Wrap(
            spacing: 4,
            children: [
              _segmented<ScratchOutStyle>(
                ScratchOutStyle.singleLine, '单线', _config.scratchOutStyle,
                (v) => _update(_config.copyWith(scratchOutStyle: v)),
              ),
              _segmented<ScratchOutStyle>(
                ScratchOutStyle.doubleLine, '双线', _config.scratchOutStyle,
                (v) => _update(_config.copyWith(scratchOutStyle: v)),
              ),
              _segmented<ScratchOutStyle>(
                ScratchOutStyle.wave, '波浪', _config.scratchOutStyle,
                (v) => _update(_config.copyWith(scratchOutStyle: v)),
              ),
              _segmented<ScratchOutStyle>(
                ScratchOutStyle.blackOut, '涂黑', _config.scratchOutStyle,
                (v) => _update(_config.copyWith(scratchOutStyle: v)),
              ),
            ],
          ),
          _slider('涂改次数', _config.scratchOutCount.toDouble(), 0, 8, 8,
              (v) => _update(_config.copyWith(scratchOutCount: v.round())),
              (v) => '${v.round()}'),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('划线颜色', style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              _colorDot(const Color(0xFFC62828), _config.scratchOutColor, (v) {
                _update(_config.copyWith(scratchOutColor: v));
              }),
              _colorDot(const Color(0xFF1A1A1A), _config.scratchOutColor, (v) {
                _update(_config.copyWith(scratchOutColor: v));
              }),
              _colorDot(const Color(0xFF1E5AA8), _config.scratchOutColor, (v) {
                _update(_config.copyWith(scratchOutColor: v));
              }),
            ],
          ),
        ],
      ],
    );
  }

  // ─── 其他 ───

  Widget _buildMiscSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '其他'),
        _slider('图片/公式弯曲度', _config.imageCurvature, 0, 1, 20,
            (v) => _update(_config.copyWith(imageCurvature: v)),
            (v) => '${(v * 100).round()}%'),
        Row(
          children: [
            const Text('随机种子', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: TextField(
                controller: _seedCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
                onSubmitted: (_) => _applySeed(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.casino_outlined, size: 18),
              tooltip: '随机种子',
              onPressed: () {
                final seed = Random().nextInt(100000);
                _seedCtrl.text = '$seed';
                _update(_config.copyWith(randomSeed: seed));
              },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '同一配置每次生成结果一致',
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ─── 工具方法 ───

  Widget _sectionTitle(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }

  Widget _segmented<T>(
    T value,
    String label,
    T selected,
    ValueChanged<T> onChanged,
  ) {
    final isSel = value == selected;
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: isSel,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => onChanged(value),
      ),
    );
  }

  Widget _colorDot(Color color, Color selected, ValueChanged<Color> onTap) {
    final isSelected = color.toARGB32() == selected.toARGB32();
    return GestureDetector(
      onTap: () => onTap(color),
      child: Container(
        width: 22,
        height: 22,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.blueAccent : Colors.black26,
            width: isSelected ? 2.5 : 1,
          ),
        ),
        child: isSelected
            ? const Icon(Icons.check, size: 13, color: Colors.black54)
            : null,
      ),
    );
  }

  /// "自定义"纸张颜色选项: 选中时显示已选自定义色, 未选时显示彩虹提示
  ///
  /// 以显式文字标签 "自定义" 呈现, 避免被误认为普通装饰色块。
  Widget _customPaperChip() {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 4),
      child: ChoiceChip(
        label: const Text('自定义', style: TextStyle(fontSize: 12)),
        selected: _isCustomPaper,
        visualDensity: VisualDensity.compact,
        avatar: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isCustomPaper ? _config.paperColor : null,
            gradient: _isCustomPaper
                ? null
                : const LinearGradient(
                    colors: [
                      Colors.red,
                      Colors.orange,
                      Colors.green,
                      Colors.blue,
                      Colors.purple,
                    ],
                  ),
            border: Border.all(color: Colors.black26, width: 1),
          ),
        ),
        onSelected: (_) => _pickCustomPaperColor(),
      ),
    );
  }

  /// 打开颜色选择器, 确认后写入 paperColor
  Future<void> _pickCustomPaperColor() async {
    final initial = _isCustomPaper ? _config.paperColor : _customPaperColor;
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => _ColorPickerDialog(initialColor: initial),
    );
    if (picked != null) {
      _customPaperColor = picked;
      _update(_config.copyWith(paperColor: picked));
    }
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int? divisions,
    ValueChanged<double> onChanged,
    String Function(double) format,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              format(value),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

/// 自包含 HSV 颜色选择器 (避免引入第三方依赖)
///
/// 支持饱和度/明度二维拾取 + 色相滑杆, 适配窄屏 (宽屏布局下亦可正常使用)。
class _ColorPickerDialog extends StatefulWidget {
  final Color initialColor;

  const _ColorPickerDialog({required this.initialColor});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  static const double _svW = 280;
  static const double _svH = 200;

  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
  }

  void _handlePan(Offset local) {
    final x = local.dx.clamp(0.0, _svW);
    final y = local.dy.clamp(0.0, _svH);
    setState(() {
      _hsv = _hsv.withSaturation(x / _svW).withValue(1 - y / _svH);
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('自定义纸张颜色'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 饱和度/明度二维拾取区
          GestureDetector(
            onPanDown: (d) => _handlePan(d.localPosition),
            onPanUpdate: (d) => _handlePan(d.localPosition),
            child: SizedBox(
              width: _svW,
              height: _svH,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black26),
                      color: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                    ),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
                        ),
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0xFF000000)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: _hsv.saturation * _svW - 8,
                    top: (1 - _hsv.value) * _svH - 8,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 色相滑杆
          Row(
            children: [
              const Text('色相', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: Slider(
                  value: _hsv.hue,
                  min: 0,
                  max: 360,
                  divisions: 360,
                  activeColor: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                  onChanged: (h) => setState(() => _hsv = _hsv.withHue(h)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 实时预览
          Container(
            width: double.infinity,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              border: Border.all(color: Colors.black26),
            ),
            child: Center(
              child: Text(
                '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
                style: TextStyle(
                  fontSize: 12,
                  color: _hsv.value > 0.5 ? Colors.black54 : Colors.white70,
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
