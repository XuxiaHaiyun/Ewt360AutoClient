/// 编辑器通用弹窗与常量：画布尺寸预设（含范围 200~4000px）、取色色板与取色弹窗、画布尺寸弹窗等。
/// 取色/尺寸弹窗返回所选结果，取消返回 null。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../answer/domain/entities/handwriting_config.dart';
import '../domain/entities/editor_config.dart';

/// 画布尺寸允许范围 (逻辑 px)
const double kMinCanvasSize = 200;
const double kMaxCanvasSize = 4000;

/// 画布尺寸预设
class CanvasSizePreset {
  final String label;
  final double width;
  final double height;
  const CanvasSizePreset(this.label, this.width, this.height);
}

const List<CanvasSizePreset> kCanvasSizePresets = [
  CanvasSizePreset('A4 竖版', 1080, 1528),
  CanvasSizePreset('A4 横版', 1528, 1080),
  CanvasSizePreset('正方形', 1080, 1080),
  CanvasSizePreset('手机竖屏', 1080, 1920),
  CanvasSizePreset('宽屏', 1920, 1080),
];

/// 编辑器通用取色色板
const List<Color> kEditorColorPalette = [
  Color(0xFF1A1A1A),
  Colors.white,
  Colors.red,
  Colors.orange,
  Colors.yellow,
  Colors.green,
  Colors.blue,
  Colors.purple,
  Colors.grey,
];

const List<String> _kEditorColorNames = [
  '黑色',
  '白色',
  '红色',
  '橙色',
  '黄色',
  '绿色',
  '蓝色',
  '紫色',
  '灰色',
];

/// 通用取色弹窗 (画笔/公式等共用)
///
/// 色板圆形色块带名称 tooltip; 返回所选 [Color], 取消返回 null。
Future<Color?> showEditorColorPickerDialog(
  BuildContext context, {
  String title = '选择颜色',
  required Color current,
}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _EditorColorPickerDialog(title: title, current: current),
  );
}

class _EditorColorPickerDialog extends StatelessWidget {
  final String title;
  final Color current;

  const _EditorColorPickerDialog({required this.title, required this.current});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < kEditorColorPalette.length; i++)
              Tooltip(
                message: _kEditorColorNames[i],
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(kEditorColorPalette[i]),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: kEditorColorPalette[i],
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: kEditorColorPalette[i] == current
                            ? Colors.blue
                            : Colors.grey,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 画布尺寸弹窗: 预设 + 自定义宽高
///
/// 返回画布尺寸 [Size] (逻辑 px), 取消返回 null。
Future<Size?> showCanvasSizeDialog(
  BuildContext context, {
  required double width,
  required double height,
}) {
  return showDialog<Size>(
    context: context,
    builder: (_) => _CanvasSizeDialog(width: width, height: height),
  );
}

class _CanvasSizeDialog extends StatefulWidget {
  final double width;
  final double height;
  const _CanvasSizeDialog({required this.width, required this.height});

  @override
  State<_CanvasSizeDialog> createState() => _CanvasSizeDialogState();
}

class _CanvasSizeDialogState extends State<_CanvasSizeDialog> {
  late final TextEditingController _wCtrl;
  late final TextEditingController _hCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _wCtrl = TextEditingController(text: widget.width.round().toString());
    _hCtrl = TextEditingController(text: widget.height.round().toString());
  }

  @override
  void dispose() {
    _wCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  bool _isCurrent(CanvasSizePreset p) =>
      p.width == widget.width && p.height == widget.height;

  double? _parse(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    if (v == null) return null;
    return v.clamp(kMinCanvasSize, kMaxCanvasSize).toDouble();
  }

  void _confirm() {
    final w = _parse(_wCtrl);
    final h = _parse(_hCtrl);
    if (w == null || h == null) {
      setState(() => _error =
          '宽高需为 ${kMinCanvasSize.round()} ~ ${kMaxCanvasSize.round()} 的数值');
      return;
    }
    Navigator.of(context).pop(Size(w, h));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('画布大小'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kCanvasSizePresets
                  .map((p) => ChoiceChip(
                        label: Text(
                          '${p.label} ${p.width.round()}×${p.height.round()}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _isCurrent(p),
                        onSelected: (_) {
                          setState(() {
                            _error = null;
                            _wCtrl.text = p.width.round().toString();
                            _hCtrl.text = p.height.round().toString();
                          });
                        },
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _wCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '宽度 (px)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('×'),
                ),
                Expanded(
                  child: TextField(
                    controller: _hCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '高度 (px)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '范围 ${kMinCanvasSize.round()} ~ ${kMaxCanvasSize.round()} px, '
              '导出按此尺寸渲染; 调整后已有组件等比缩放',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}

/// 画布背景弹窗 (纯色/自定义颜色/自定义图片/手写模拟纸张)
///
/// 返回新背景 [EditorBackground], 取消返回 null。
Future<EditorBackground?> showCanvasBackgroundDialog(
  BuildContext context,
  EditorBackground initial,
) {
  return showDialog<EditorBackground>(
    context: context,
    builder: (_) => _CanvasBackgroundDialog(initial: initial),
  );
}

class _CanvasBackgroundDialog extends StatefulWidget {
  final EditorBackground initial;
  const _CanvasBackgroundDialog({required this.initial});

  @override
  State<_CanvasBackgroundDialog> createState() =>
      _CanvasBackgroundDialogState();
}

class _CanvasBackgroundDialogState extends State<_CanvasBackgroundDialog> {
  late EditorBackground _bg;

  @override
  void initState() {
    super.initState();
    _bg = widget.initial;
  }

  Future<void> _pickImage() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (res != null && res.files.isNotEmpty) {
      final f = res.files.first;
      setState(() => _bg = _bg.copyWith(
            type: EditorBackgroundType.customImage,
            imageBytes: f.bytes,
            imageName: f.name,
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('画布背景'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('类型'),
            Wrap(
              spacing: 8,
              children: EditorBackgroundType.values
                  .map((t) => ChoiceChip(
                        label: Text(_bgTypeLabel(t)),
                        selected: _bg.type == t,
                        onSelected: (_) =>
                            setState(() => _bg = _bg.copyWith(type: t)),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            if (_bg.type == EditorBackgroundType.solid ||
                _bg.type == EditorBackgroundType.customColor)
              Wrap(
                spacing: 8,
                children: [
                  Colors.white,
                  Colors.yellow.shade100,
                  const Color(0xFF8FB6E8),
                  const Color(0xFFFFE0B2),
                  Colors.green.shade100,
                  Colors.black,
                ]
                    .map((c) => GestureDetector(
                          onTap: () =>
                              setState(() => _bg = _bg.copyWith(color: c)),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c,
                              border: Border.all(
                                color: _bg.color == c ? Colors.blue : Colors.grey,
                                width: 2,
                              ),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            if (_bg.type == EditorBackgroundType.customImage)
              TextButton.icon(
                icon: const Icon(Icons.image),
                label: const Text('选择背景图片'),
                onPressed: _pickImage,
              ),
            if (_bg.type == EditorBackgroundType.handwritingPaper) ...[
              const SizedBox(height: 8),
              const Text('纸张样式'),
              Wrap(
                spacing: 8,
                children: HandwritingPaperType.values
                    .map((p) => ChoiceChip(
                          label: Text(_paperLabel(p)),
                          selected: _bg.paperType == p,
                          onSelected: (_) =>
                              setState(() => _bg = _bg.copyWith(paperType: p)),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 8),
              const Text('纸张颜色'),
              Wrap(
                spacing: 8,
                children: [
                  Colors.white,
                  const Color(0xFFFFF8E1),
                  const Color(0xFFE3F2FD),
                  Colors.red.shade50,
                ]
                    .map((c) => GestureDetector(
                          onTap: () =>
                              setState(() => _bg = _bg.copyWith(paperColor: c)),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: c,
                              border: Border.all(color: Colors.grey),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _bg),
          child: const Text('确定'),
        ),
      ],
    );
  }

  String _bgTypeLabel(EditorBackgroundType t) => switch (t) {
        EditorBackgroundType.solid => '纯色',
        EditorBackgroundType.customColor => '自定义颜色',
        EditorBackgroundType.customImage => '自定义图片',
        EditorBackgroundType.handwritingPaper => '手写纸张',
      };

  String _paperLabel(HandwritingPaperType p) => switch (p) {
        HandwritingPaperType.blank => '空白',
        HandwritingPaperType.ruled => '横线',
        HandwritingPaperType.grid => '方格',
        HandwritingPaperType.tianzige => '田字格',
      };
}
