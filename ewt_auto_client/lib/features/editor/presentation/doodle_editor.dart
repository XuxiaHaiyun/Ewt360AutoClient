/// 独立涂鸦编辑器，画布背景与编辑器一致（纯色/自定义颜色/图片/手写纸张），笔画以归一化坐标存储便于复用。
/// 外部经 GlobalKey 调用 DoodleEditorState.snapshot 读取结果（笔画 + 背景）。
library;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../../answer/domain/entities/handwriting_config.dart';
import '../domain/entities/editor_config.dart';
import 'canvas_background.dart';

/// 涂鸦编辑器返回结果 (笔画 + 背景)
class DoodleResult {
  final List<DoodleStroke> strokes;
  final EditorBackground background;
  const DoodleResult(this.strokes, this.background);
}

/// 涂鸦编辑器
///
/// 在独立的画布上自由绘制, 画布背景支持与编辑器一致的四类选择
/// (纯色 / 自定义颜色 / 自定义图片 / 手写模拟同款纸张)。
/// 笔画以归一化坐标存储, 便于缩放/旋转复用。
class DoodleEditor extends StatefulWidget {
  final List<DoodleStroke> initialStrokes;
  final EditorBackground initialBackground;
  final double width;
  final double height;

  const DoodleEditor({
    super.key,
    this.initialStrokes = const [],
    this.initialBackground = const EditorBackground(),
    this.width = 720,
    this.height = 720,
  });

  @override
  State<DoodleEditor> createState() => DoodleEditorState();
}

/// 涂鸦编辑器状态 (公开以便外部通过 GlobalKey 读取结果)
class DoodleEditorState extends State<DoodleEditor> {
  late List<DoodleStroke> _strokes;
  late EditorBackground _background;
  Color _penColor = const Color(0xFF1A1A1A);
  double _penWidth = 3;
  DoodleStroke? _current;
  final _canvasKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _strokes = List.from(widget.initialStrokes);
    _background = widget.initialBackground;
  }

  /// 当前结果 (笔画 + 背景)
  DoodleResult snapshot() => DoodleResult(_strokes, _background);

  void _begin(Offset local) {
    final box =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size(widget.width, widget.height);
    final nx = (local.dx / size.width).clamp(0.0, 1.0);
    final ny = (local.dy / size.height).clamp(0.0, 1.0);
    _current = DoodleStroke(
      points: [OffsetN(nx, ny)],
      colorArgb: _penColor.toARGB32(),
      width: _penWidth,
    );
    setState(() => _strokes.add(_current!));
  }

  void _extend(Offset local) {
    if (_current == null) return;
    final box =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size(widget.width, widget.height);
    final nx = (local.dx / size.width).clamp(0.0, 1.0);
    final ny = (local.dy / size.height).clamp(0.0, 1.0);
    setState(() {
      _strokes[_strokes.length - 1] = _current!.copyWith(
        points: [..._current!.points, OffsetN(nx, ny)],
      );
      _current = _strokes.last;
    });
  }

  void _end() => _current = null;

  void _undo() {
    if (_strokes.isNotEmpty) setState(() => _strokes.removeLast());
  }

  Future<void> _pickImage() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (res != null && res.files.isNotEmpty) {
      final f = res.files.first;
      setState(() => _background = _background.copyWith(
            type: EditorBackgroundType.customImage,
            imageBytes: f.bytes,
            imageName: f.name,
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _toolbar(context),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: widget.width / widget.height,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                ),
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: buildDoodleBackgroundWidget(
                          _background,
                          widget.width,
                          widget.height,
                        ),
                      ),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: DoodlePainter(
                            strokes: _strokes,
                            width: widget.width,
                            height: widget.height,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: GestureDetector(
                          key: _canvasKey,
                          onPanStart: (e) => _begin(e.localPosition),
                          onPanUpdate: (e) => _extend(e.localPosition),
                          onPanEnd: (_) => _end(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.undo),
          tooltip: '撤销',
          onPressed: _undo,
        ),
        ...[const Color(0xFF1A1A1A), Colors.red, Colors.blue, Colors.green]
            .map((c) => GestureDetector(
                  onTap: () => setState(() => _penColor = c),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _penColor == c ? Colors.blue : Colors.grey,
                        width: 2,
                      ),
                    ),
                  ),
                )),
        SizedBox(
          width: 140,
          child: Slider(
            value: _penWidth,
            min: 1,
            max: 20,
            label: '笔宽 ${_penWidth.toInt()}',
            onChanged: (v) => setState(() => _penWidth = v),
          ),
        ),
        TextButton.icon(
          icon: const Icon(Icons.image),
          label: const Text('背景图'),
          onPressed: _pickImage,
        ),
        PopupMenuButton<EditorBackgroundType>(
          icon: const Icon(Icons.texture),
          tooltip: '画布类型',
          onSelected: (t) => setState(() {
            _background = _background.copyWith(type: t);
          }),
          itemBuilder: (_) => const [
            PopupMenuItem(
                value: EditorBackgroundType.solid, child: Text('纯色')),
            PopupMenuItem(
                value: EditorBackgroundType.customColor,
                child: Text('自定义颜色')),
            PopupMenuItem(
                value: EditorBackgroundType.customImage,
                child: Text('自定义图片')),
            PopupMenuItem(
                value: EditorBackgroundType.handwritingPaper,
                child: Text('手写模拟纸张')),
          ],
        ),
        if (_background.type == EditorBackgroundType.customColor)
          IconButton(
            icon: const Icon(Icons.color_lens),
            tooltip: '选择颜色',
            onPressed: () async {
              final c = await _pickColor(context);
              if (c != null) {
                setState(() => _background = _background.copyWith(color: c));
              }
            },
          ),
        if (_background.type == EditorBackgroundType.handwritingPaper)
          PopupMenuButton<HandwritingPaperType>(
            icon: const Icon(Icons.grid_4x4),
            tooltip: '纸张样式',
            onSelected: (p) =>
                setState(() => _background = _background.copyWith(paperType: p)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: HandwritingPaperType.blank, child: Text('空白')),
              PopupMenuItem(value: HandwritingPaperType.ruled, child: Text('横线')),
              PopupMenuItem(value: HandwritingPaperType.grid, child: Text('方格')),
              PopupMenuItem(
                  value: HandwritingPaperType.tianzige, child: Text('田字格')),
            ],
          ),
      ],
    );
  }

  Future<Color?> _pickColor(BuildContext context) async {
    Color? chosen;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择颜色'),
        content: SingleChildScrollView(
          child: Wrap(
            spacing: 8,
            children: [
              Colors.red,
              Colors.orange,
              Colors.yellow,
              Colors.green,
              Colors.blue,
              Colors.purple,
              Colors.black,
              Colors.white,
              const Color(0xFF8FB6E8),
            ]
                .map((c) => GestureDetector(
                      onTap: () {
                        chosen = c;
                        Navigator.of(ctx).pop();
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          border: Border.all(color: Colors.grey),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
      ),
    );
    return chosen;
  }
}
