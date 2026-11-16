/// 编辑器提交页，可平移/缩放画布上集成文本/图片/公式/涂鸦四类可变换组件，画笔模式下单指涂鸦双指平移。
/// 支持撤销/重做与组件手柄变换；确认后返回 EditorConfig，导出 PNG 供提交流程作为主观题附件。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../answer/presentation/widgets/answer_editor/latex_input.dart';
import '../domain/entities/editor_config.dart';
import 'canvas_background.dart';
import 'doodle_editor.dart';
import 'editor_dialogs.dart';
import 'transformable.dart';

/// 画笔样式
enum _PenStyle {
  /// 普通画笔
  normal,

  /// 荧光笔 (半透明、较粗)
  highlighter,
}

/// 编辑器提交页
///
/// 画布是一块可无限平移/缩放的设计板: 1 画布 px = 1 逻辑 px, [InteractiveViewer]
/// 负责整体平移与缩放 (打开时整页适配视口, 可自由放大后平移编辑)。
/// 集成 文本/图片/公式/涂鸦 四类可变换组件; 画笔模式下单指涂鸦、
/// 双指仍可平移缩放画布。导出为 PNG 供提交流程作为主观题附件使用。
class EditorPage extends StatefulWidget {
  final EditorConfig initial;
  final void Function(EditorConfig) onConfirm;

  const EditorPage({
    super.key,
    required this.initial,
    required this.onConfirm,
  });

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  /// 缩放范围
  static const double _minZoom = 0.1;
  static const double _maxZoom = 8;

  late EditorConfig _config;
  String? _selectedId;

  /// 撤销 / 重做栈 (存变更前/后的完整配置)
  final List<EditorConfig> _undoStack = [];
  final List<EditorConfig> _redoStack = [];

  /// 画布视口变换 (平移 + 缩放)
  final TransformationController _transformCtrl = TransformationController();
  double _zoom = 1;

  /// 画布可视区尺寸 (LayoutBuilder 记录, 用于整页适配与新增组件定位)
  Size _viewport = Size.zero;
  bool _fitted = false;

  final _ivKey = GlobalKey();
  final _canvasKey = GlobalKey();

  /// 是否处于画笔 (直接在画布涂鸦) 模式
  bool _drawing = false;

  /// 当前画笔会话已完成的笔画 (归一化坐标 0~1, 相对整张画布)
  List<DoodleStroke> _penStrokes = [];

  /// 画笔颜色 / 视觉粗细 / 样式
  Color _penColor = const Color(0xFF1A1A1A);
  double _penWidth = 4;
  _PenStyle _penStyle = _PenStyle.normal;

  static const List<Color> _penPalette = [
    Color(0xFF1A1A1A),
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.white,
  ];

  @override
  void initState() {
    super.initState();
    _config = widget.initial;
    _transformCtrl.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  // ─── 视口 (平移 / 缩放 / 适配) ───

  void _onTransformChanged() {
    final z = _transformCtrl.value.getMaxScaleOnAxis();
    if ((z - _zoom).abs() > 0.0005) setState(() => _zoom = z);
  }

  /// 整页适配视口并居中 (首次布局后调用)
  void _ensureFitted() {
    if (_fitted || _viewport == Size.zero) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyFit();
    });
  }

  double _fitScale() {
    if (_viewport == Size.zero ||
        _config.canvasWidth <= 0 ||
        _config.canvasHeight <= 0) {
      return 1;
    }
    final s = math.min(
      _viewport.width / _config.canvasWidth,
      _viewport.height / _config.canvasHeight,
    );
    return s.clamp(_minZoom, 1.0).toDouble();
  }

  /// 构建纯平移 + 均匀缩放的视口矩阵
  ///
  /// 注意三轴都要缩放: getMaxScaleOnAxis 取三轴最大值, z 轴为 1 会使
  /// 缩放读数恒为 1。
  Matrix4 _translateScaleMatrix(double tx, double ty, double scale) {
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  /// 整页适配视口并居中
  void _applyFit() {
    if (_viewport == Size.zero) return;
    final s = _fitScale();
    final dx = (_viewport.width - _config.canvasWidth * s) / 2;
    final dy = (_viewport.height - _config.canvasHeight * s) / 2;
    _transformCtrl.value = _translateScaleMatrix(dx, dy, s);
  }

  /// 以视口坐标 [focal] 为焦点缩放到 [target], 保持焦点下的画布点不动
  void _zoomAt(Offset focal, double target) {
    final m = _transformCtrl.value;
    final s = m.getMaxScaleOnAxis();
    if (s <= 0) return;
    final t = m.getTranslation();
    final sNew = target.clamp(_minZoom, _maxZoom).toDouble();
    final tx = focal.dx - (focal.dx - t.x) * (sNew / s);
    final ty = focal.dy - (focal.dy - t.y) * (sNew / s);
    _transformCtrl.value = _translateScaleMatrix(tx, ty, sNew);
  }

  /// 以视口中心为焦点按 [factor] 缩放
  void _zoomStep(double factor) =>
      _zoomAt(_viewport.center(Offset.zero), _zoom * factor);

  /// 桌面端鼠标滚轮: 以光标为焦点缩放
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final factor = event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1;
    _zoomAt(_viewportFocal(event.position), _zoom * factor);
  }

  /// 全局坐标 → 视口坐标 (缩放焦点)
  Offset _viewportFocal(Offset global) {
    final box = _ivKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return _viewport.center(Offset.zero);
    return box.globalToLocal(global);
  }

  /// 空白处双击: 整页适配 ↔ 放大一倍
  void _onCanvasDoubleTap() {
    final fit = _fitScale();
    if ((_zoom - fit).abs() < 0.05) {
      _zoomStep(2);
    } else {
      _applyFit();
    }
  }

  // ─── 撤销 / 重做 ───

  /// 在任何修改性操作前调用, 记录当前配置
  void _snapshot() {
    _undoStack.add(_config);
    if (_undoStack.length > 60) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _redoStack.add(_config);
      _config = _undoStack.removeLast();
      _selectedId = null;
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      _undoStack.add(_config);
      _config = _redoStack.removeLast();
      _selectedId = null;
    });
  }

  // ─── 组件增删改 ───

  EditorComponent? get _selected {
    if (_selectedId == null) return null;
    for (final c in _config.components) {
      if (c.id == _selectedId) return c;
    }
    return null;
  }

  void _update(EditorComponent c) {
    setState(() {
      _config = _config.copyWith(
        components: _config.components
            .map((e) => e.id == c.id ? c : e)
            .toList(),
      );
    });
  }

  void _add(EditorComponent c) {
    _snapshot();
    setState(() {
      _config = _config.copyWith(components: [..._config.components, c]);
      _selectedId = c.id;
    });
  }

  String _newId() => 'c_${DateTime.now().microsecondsSinceEpoch}';

  void _deselect() => setState(() => _selectedId = null);

  /// 新组件默认放在当前视口中心 (画布坐标), 并限制在画布内
  Offset _placementFor(Size size) {
    final m = _transformCtrl.value;
    final s = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    final cx = (_viewport.width / 2 - t.x) / s;
    final cy = (_viewport.height / 2 - t.y) / s;
    final maxX = math.max(0.0, _config.canvasWidth - size.width);
    final maxY = math.max(0.0, _config.canvasHeight - size.height);
    return Offset(
      (cx - size.width / 2).clamp(0.0, maxX).toDouble(),
      (cy - size.height / 2).clamp(0.0, maxY).toDouble(),
    );
  }

  /// 文本内容 + 字号弹窗 (添加与编辑共用)
  ///
  /// controller 由弹窗 State 持有, 随路由退场动画结束后释放,
  /// 避免在退场动画期间 dispose 导致 TextField 使用已释放的 controller。
  Future<(String, double)?> _showTextPrompt({
    required String title,
    String? initialText,
    double initialFontSize = 24,
  }) {
    return showDialog<(String, double)>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: title,
        initialText: initialText,
        initialFontSize: initialFontSize,
      ),
    );
  }

  Future<void> _addText() async {
    final r = await _showTextPrompt(title: '添加文本');
    if (r == null || r.$1.isEmpty || !mounted) return;
    final w = math.min(480.0, _config.canvasWidth * 0.6);
    final h = math.max(80.0, _config.canvasHeight * 0.08);
    final pos = _placementFor(Size(w, h));
    _add(EditorComponent(
      id: _newId(),
      type: EditorComponentType.text,
      text: r.$1,
      textFontSize: r.$2,
      x: pos.dx,
      y: pos.dy,
      width: w,
      height: h,
    ));
  }

  Future<void> _addImage() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (res == null || res.files.isEmpty || !mounted) return;
    final f = res.files.first;
    final bytes = f.bytes;
    if (bytes == null || bytes.isEmpty) return;

    // 读取图片真实宽高, 默认占画布一半且保持纵横比
    Size imgSize = const Size(4, 3);
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      imgSize = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      codec.dispose();
    } catch (_) {}

    final maxW = _config.canvasWidth * 0.5;
    final maxH = _config.canvasHeight * 0.5;
    var w = maxW;
    var h = w * imgSize.height / imgSize.width;
    if (h > maxH) {
      h = maxH;
      w = h * imgSize.width / imgSize.height;
    }
    final pos = _placementFor(Size(w, h));
    _add(EditorComponent(
      id: _newId(),
      type: EditorComponentType.image,
      imageBytes: bytes,
      imageName: f.name,
      x: pos.dx,
      y: pos.dy,
      width: w,
      height: h,
    ));
  }

  Future<void> _addFormula() async {
    final latex = await showFormulaDialog(context);
    if (latex != null && latex.trim().isNotEmpty && mounted) {
      final w = _config.canvasWidth * 0.35;
      final h = math.max(80.0, _config.canvasHeight * 0.07);
      final pos = _placementFor(Size(w, h));
      _add(EditorComponent(
        id: _newId(),
        type: EditorComponentType.formula,
        latex: latex.trim(),
        formulaFontSize: 28,
        x: pos.dx,
        y: pos.dy,
        width: w,
        height: h,
      ));
    }
  }

  Future<void> _editDoodle(EditorComponent c) async {
    final r = await Navigator.of(context)
        .push<DoodleResult>(
      MaterialPageRoute(
        builder: (_) => _DoodleRoute(
          initialStrokes: c.doodleStrokes ?? const [],
          initialBackground: c.doodleBackground ?? const EditorBackground(),
        ),
      ),
    );
    if (r != null) {
      _snapshot();
      _update(c.copyWith(doodleStrokes: r.strokes, doodleBackground: r.background));
    }
  }

  void _deleteSelected() {
    if (_selectedId == null) return;
    _snapshot();
    setState(() {
      _config = _config.copyWith(
        components:
            _config.components.where((e) => e.id != _selectedId).toList(),
      );
      _selectedId = null;
    });
  }

  Future<void> _confirm() async {
    widget.onConfirm(_config);
    if (mounted) Navigator.of(context).pop(_config);
  }

  void _bringToFront(EditorComponent c) {
    _snapshot();
    setState(() {
      _config = _config.copyWith(
        components: [
          ..._config.components.where((e) => e.id != c.id),
          c,
        ],
      );
    });
  }

  void _sendToBack(EditorComponent c) {
    _snapshot();
    setState(() {
      _config = _config.copyWith(
        components: [
          c,
          ..._config.components.where((e) => e.id != c.id),
        ],
      );
    });
  }

  void _duplicate(EditorComponent c) {
    _snapshot();
    final copy = c.copyWith(id: _newId());
    setState(() {
      final idx = _config.components.indexWhere((e) => e.id == c.id);
      final list = List<EditorComponent>.from(_config.components);
      list.insert(idx + 1, copy);
      _config = _config.copyWith(components: list);
      _selectedId = copy.id;
    });
  }

  void _clearAll() {
    _snapshot();
    setState(() {
      _config = _config.copyWith(components: const []);
      _selectedId = null;
    });
  }

  void _editComponent(EditorComponent c) {
    switch (c.type) {
      case EditorComponentType.text:
        _editText(c);
      case EditorComponentType.formula:
        _editFormula(c);
      case EditorComponentType.doodle:
        _editDoodle(c);
      case EditorComponentType.image:
        break;
    }
  }

  // ─── 画布尺寸 / 背景 ───

  Future<void> _editCanvasSize() async {
    final size = await showCanvasSizeDialog(
      context,
      width: _config.canvasWidth,
      height: _config.canvasHeight,
    );
    if (size == null || !mounted) return;
    _snapshot();
    setState(() {
      _config = _config.resized(size.width, size.height);
    });
    _applyFit();
  }

  Future<void> _editCanvas() async {
    final bg = await showCanvasBackgroundDialog(context, _config.background);
    if (bg == null || !mounted) return;
    _snapshot();
    setState(() => _config = _config.copyWith(background: bg));
  }

  // ─── 画笔 (直接在画布涂鸦) ───

  /// 切换画笔模式: 开启时清空当前笔画, 关闭时把已画笔画固化为涂鸦组件
  void _togglePen() {
    if (_drawing) {
      _finishPen();
    } else {
      setState(() {
        _drawing = true;
        _penStrokes = [];
        _selectedId = null;
      });
    }
  }

  /// 结束画笔模式: 把当前笔画固化为一个可拖动/缩放/旋转的涂鸦组件
  void _finishPen() {
    if (_penStrokes.isNotEmpty) {
      _add(_buildDoodleComponent(_penStrokes));
    }
    setState(() {
      _drawing = false;
      _penStrokes = [];
    });
  }

  /// 由归一化笔画 (相对整张画布) 生成只覆盖笔画范围的涂鸦组件
  EditorComponent _buildDoodleComponent(List<DoodleStroke> strokes) {
    double minX = 1, minY = 1, maxX = 0, maxY = 0;
    for (final s in strokes) {
      for (final p in s.points) {
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
      }
    }
    const pad = 0.02;
    minX = (minX - pad).clamp(0.0, 1.0);
    minY = (minY - pad).clamp(0.0, 1.0);
    maxX = (maxX + pad).clamp(0.0, 1.0);
    maxY = (maxY + pad).clamp(0.0, 1.0);
    final bw = (maxX - minX).clamp(0.02, 1.0);
    final bh = (maxY - minY).clamp(0.02, 1.0);
    final renorm = strokes.map((s) {
      return DoodleStroke(
        points: s.points
            .map((p) => OffsetN(
                  ((p.x - minX) / bw).clamp(0.0, 1.0),
                  ((p.y - minY) / bh).clamp(0.0, 1.0),
                ))
            .toList(),
        colorArgb: s.colorArgb,
        width: s.width,
      );
    }).toList();
    return EditorComponent(
      id: _newId(),
      type: EditorComponentType.doodle,
      // 透明背景: 仅叠加笔画, 不遮挡画布与其它组件
      doodleBackground: const EditorBackground(
        type: EditorBackgroundType.solid,
        color: Color(0x00000000),
      ),
      doodleStrokes: renorm,
      x: minX * _config.canvasWidth,
      y: minY * _config.canvasHeight,
      width: bw * _config.canvasWidth,
      height: bh * _config.canvasHeight,
      scale: 1,
      rotation: 0,
    );
  }

  void _penUndo() {
    if (_penStrokes.isEmpty) return;
    setState(() => _penStrokes = List.from(_penStrokes)..removeLast());
  }

  void _penClear() => setState(() => _penStrokes = []);

  Color get _effectivePenColor => _penStyle == _PenStyle.highlighter
      ? _penColor.withValues(alpha: 0.4)
      : _penColor;

  /// 笔画在画布坐标系的实际宽度: 以屏幕视觉粗细为准 (所见即所得), 随缩放换算
  double get _effectivePenCanvasWidth {
    final visual =
        _penStyle == _PenStyle.highlighter ? _penWidth * 3 : _penWidth;
    return (visual / _zoom).clamp(0.5, 96.0).toDouble();
  }

  Future<void> _pickPenColor() async {
    final chosen = await showEditorColorPickerDialog(
      context,
      title: '选择画笔颜色',
      current: _penColor,
    );
    if (chosen != null && mounted) setState(() => _penColor = chosen);
  }

  /// 公式颜色: 属性面板色块 → 取色弹窗
  Future<void> _editFormulaColor(EditorComponent c) async {
    final chosen = await showEditorColorPickerDialog(
      context,
      title: '选择公式颜色',
      current: Color(c.formulaColorArgb ?? 0xFF000000),
    );
    if (chosen == null || !mounted) return;
    _snapshot();
    _update(c.copyWith(formulaColorArgb: chosen.toARGB32()));
  }

  // ─── 文本 / 公式编辑 ───

  Future<void> _editText(EditorComponent c) async {
    final r = await _showTextPrompt(
      title: '编辑文本',
      initialText: c.text ?? '',
      initialFontSize: c.textFontSize ?? 24,
    );
    if (r == null || !mounted) return;
    _snapshot();
    _update(c.copyWith(text: r.$1, textFontSize: r.$2));
  }

  Future<void> _editFormula(EditorComponent c) async {
    final latex = await showFormulaDialog(context, initial: c.latex);
    if (latex != null && mounted) {
      _snapshot();
      _update(c.copyWith(latex: latex.trim()));
    }
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    final sel = _selected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑器提交'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '完成',
            onPressed: _confirm,
          ),
        ],
      ),
      body: Column(
        children: [
          _toolbar(),
          if (_drawing) _penBar(),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _viewport = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      _ensureFitted();
                      return Listener(
                        onPointerSignal: _onPointerSignal,
                        child: InteractiveViewer(
                          key: _ivKey,
                          transformationController: _transformCtrl,
                          panEnabled: !_drawing,
                          scaleEnabled: !_drawing,
                          minScale: _minZoom,
                          maxScale: _maxZoom,
                          constrained: false,
                          boundaryMargin:
                              const EdgeInsets.all(double.infinity),
                          child: _buildCanvas(),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(right: 12, bottom: 12, child: _zoomPill()),
                // 空画布提示: 视口层居中 (不随画布缩放变化)
                if (_config.components.isEmpty && !_drawing)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Text(
                          '空白画布\n用下方工具添加文本 / 图片 / 公式, 或开启画笔涂鸦\n双指拖动可平移缩放画布',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (sel != null && !_drawing) _propertyPanel(sel),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    final cw = _config.canvasWidth;
    final ch = _config.canvasHeight;
    return Container(
      width: cw,
      height: ch,
      decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade600)),
      child: Stack(
        key: _canvasKey,
        children: [
          Positioned.fill(
            // Listener 指针按下即取消选中, 不经手势竞技场; 组件命中时
            // (opaque) 不会传播到此处。保留 onDoubleTap 用于双击缩放切换。
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _drawing ? null : (_) => _deselect(),
              child: GestureDetector(
                onDoubleTap: _drawing ? null : _onCanvasDoubleTap,
                child: buildEditorBackgroundWidget(_config.background, cw, ch),
              ),
            ),
          ),
          // 画笔模式下组件不参与命中: 单指稳定涂鸦, 双指由画笔层接管平移缩放
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _drawing,
              child: Stack(
                children: _config.components
                    .map((c) => TransformableComponent(
                          component: c,
                          viewScale: _zoom,
                          selected: c.id == _selectedId,
                          canvasKey: _canvasKey,
                          onChanged: _update,
                          onSelect: () => setState(() => _selectedId = c.id),
                          onGestureStart: _snapshot,
                          onDoubleTap: _editComponent,
                        ))
                    .toList(),
              ),
            ),
          ),
          if (_drawing)
            Positioned.fill(
              child: _PenLayer(
                canvasWidth: cw,
                canvasHeight: ch,
                committed: _penStrokes,
                color: _effectivePenColor,
                canvasStrokeWidth: _effectivePenCanvasWidth,
                transform: _transformCtrl,
                minZoom: _minZoom,
                maxZoom: _maxZoom,
                onCommit: (s) =>
                    setState(() => _penStrokes = [..._penStrokes, s]),
              ),
            ),
        ],
      ),
    );
  }

  /// 工具栏: 添加类工具 | 撤销/重做/清空
  Widget _toolbar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _tool(Icons.text_fields, '文本', _addText),
            _tool(Icons.image, '图片', _addImage),
            _tool(Icons.functions, '公式', _addFormula),
            _tool(Icons.brush, '画笔', _togglePen, active: _drawing),
            _tool(Icons.aspect_ratio, '尺寸', _editCanvasSize),
            _tool(Icons.texture, '背景', _editCanvas),
            SizedBox(width: 4),
            Container(width: 1, height: 22, color: scheme.outlineVariant),
            const SizedBox(width: 8),
            _tool(Icons.undo, '撤销', _undoStack.isEmpty ? null : _undo),
            _tool(Icons.redo, '重做', _redoStack.isEmpty ? null : _redo),
            _tool(
              Icons.cleaning_services_outlined,
              '清空',
              _config.components.isEmpty ? null : _clearAll,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tool(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final fg = active
        ? scheme.onPrimaryContainer
        : enabled
            ? scheme.onSurface
            : scheme.onSurface.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest
                .withValues(alpha: enabled ? 1 : 0.45),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 5),
                Text(label, style: TextStyle(fontSize: 13, color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 缩放控制浮层: 缩小 / 百分比 / 放大 / 整页适配
  Widget _zoomPill() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.92),
      shape: StadiumBorder(
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove, size: 18),
              tooltip: '缩小',
              onPressed: () => _zoomStep(1 / 1.25),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${(_zoom * 100).round()}%',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              tooltip: '放大',
              onPressed: () => _zoomStep(1.25),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fit_screen_outlined, size: 18),
              tooltip: '整页适配',
              onPressed: _applyFit,
            ),
          ],
        ),
      ),
    );
  }

  /// 画笔设置条: 样式/颜色/粗细/撤销/清空/完成
  Widget _penBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Text('画笔',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('普通', style: TextStyle(fontSize: 12)),
              selected: _penStyle == _PenStyle.normal,
              onSelected: (_) => setState(() => _penStyle = _PenStyle.normal),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('荧光笔', style: TextStyle(fontSize: 12)),
              selected: _penStyle == _PenStyle.highlighter,
              onSelected: (_) =>
                  setState(() => _penStyle = _PenStyle.highlighter),
            ),
            const SizedBox(width: 12),
            ..._penPalette.map(
              (c) => GestureDetector(
                onTap: () => setState(() => _penColor = c),
                child: Container(
                  width: 26,
                  height: 26,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: c,
                    border: Border.all(
                      color: _penColor == c ? Colors.blue : Colors.grey,
                      width: 2,
                    ),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.color_lens, size: 20),
              tooltip: '自定义颜色',
              onPressed: _pickPenColor,
            ),
            const SizedBox(width: 12),
            const Text('粗细', style: TextStyle(fontSize: 12)),
            SizedBox(
              width: 130,
              child: Slider(
                value: _penWidth,
                min: 1,
                max: 24,
                label: _penWidth.toInt().toString(),
                onChanged: (v) => setState(() => _penWidth = v),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.undo, size: 20),
              tooltip: '撤销',
              onPressed: _penStrokes.isEmpty ? null : _penUndo,
            ),
            TextButton(
              onPressed: _penStrokes.isEmpty ? null : _penClear,
              child: const Text('清空'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _finishPen,
              child: const Text('完成绘制'),
            ),
          ],
        ),
      ),
    );
  }

  /// 选中组件属性条: 编辑 / 旋转 / 缩放 / 层级 / 复制 / 删除
  Widget _propertyPanel(EditorComponent sel) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Colors.grey.shade100,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (sel.type == EditorComponentType.text)
              _miniButton(Icons.edit, '编辑文本', () => _editText(sel)),
            if (sel.type == EditorComponentType.formula) ...[
              _miniButton(Icons.functions, '编辑公式', () => _editFormula(sel)),
              // 公式颜色圆点 (默认黑), 点击打开取色弹窗
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Tooltip(
                  message: '公式颜色',
                  child: GestureDetector(
                    onTap: () => _editFormulaColor(sel),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Color(sel.formulaColorArgb ?? 0xFF000000),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.grey, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (sel.type == EditorComponentType.doodle)
              _miniButton(Icons.brush, '编辑涂鸦', () => _editDoodle(sel)),
            if (sel.type != EditorComponentType.image)
              const SizedBox(width: 12),
            const Text('旋转', style: TextStyle(fontSize: 12)),
            SizedBox(
              width: 110,
              child: Slider(
                value: sel.rotation.clamp(-180.0, 180.0).toDouble(),
                min: -180,
                max: 180,
                label: '${sel.rotation.round()}°',
                onChangeStart: (_) => _snapshot(),
                onChanged: (v) => _update(sel.copyWith(rotation: v)),
              ),
            ),
            const SizedBox(width: 12),
            const Text('缩放', style: TextStyle(fontSize: 12)),
            SizedBox(
              width: 110,
              child: Slider(
                value: sel.scale.clamp(0.2, 8.0).toDouble(),
                min: 0.2,
                max: 8,
                label: sel.scale.toStringAsFixed(2),
                onChangeStart: (_) => _snapshot(),
                onChanged: (v) => _update(sel.copyWith(scale: v)),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.vertical_align_top, size: 20),
              tooltip: '置顶',
              onPressed: () => _bringToFront(sel),
            ),
            IconButton(
              icon: const Icon(Icons.vertical_align_bottom, size: 20),
              tooltip: '置底',
              onPressed: () => _sendToBack(sel),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              tooltip: '复制',
              onPressed: () => _duplicate(sel),
            ),
            IconButton(
              icon: Icon(Icons.delete, size: 20, color: Colors.red.shade700),
              tooltip: '删除',
              onPressed: _deleteSelected,
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniButton(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: onTap,
    );
  }
}

/// 画布上的画笔输入层
///
/// 覆盖在画布之上, 单指直接绘制自由笔画; 第二根手指按下时丢弃未完成笔画并
/// 转入双指会话, 增量驱动 [TransformationController] 实现平移/缩放
/// (与选择模式 InteractiveViewer 的手势结果一致)。
/// 笔画以归一化坐标 (0~1, 相对整张画布) 记录, 实时预览并逐笔回调提交。
class _PenLayer extends StatefulWidget {
  final double canvasWidth;
  final double canvasHeight;
  final List<DoodleStroke> committed;
  final Color color;

  /// 笔画在画布坐标系的宽度 (已按当前缩放换算, 所见即所得)
  final double canvasStrokeWidth;
  final TransformationController transform;
  final double minZoom;
  final double maxZoom;
  final void Function(DoodleStroke) onCommit;

  const _PenLayer({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.committed,
    required this.color,
    required this.canvasStrokeWidth,
    required this.transform,
    required this.minZoom,
    required this.maxZoom,
    required this.onCommit,
  });

  @override
  State<_PenLayer> createState() => _PenLayerState();
}

class _PenLayerState extends State<_PenLayer> {
  /// 按下的指针 → 画布局部坐标
  final Map<int, Offset> _pointers = {};

  /// 双指变换会话进行中
  bool _twoFinger = false;
  Offset? _prevMid;
  double? _prevDist;

  DoodleStroke? _current;

  OffsetN _normalize(Offset local) => OffsetN(
        (local.dx / widget.canvasWidth).clamp(0.0, 1.0),
        (local.dy / widget.canvasHeight).clamp(0.0, 1.0),
      );

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_twoFinger) return;
    if (_pointers.length == 1) {
      _current = DoodleStroke(
        points: [_normalize(e.localPosition)],
        colorArgb: widget.color.toARGB32(),
        width: widget.canvasStrokeWidth,
      );
      setState(() {});
    } else if (_pointers.length >= 2) {
      // 第二根手指按下: 丢弃未完成笔画, 转入双指平移/缩放
      _current = null;
      _twoFinger = true;
      _updateTwoFingerBase();
      setState(() {});
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_twoFinger) {
      if (_pointers.length >= 2) _applyTwoFingerTransform();
      return;
    }
    if (_current == null) return;
    setState(() {
      _current = _current!
          .copyWith(points: [..._current!.points, _normalize(e.localPosition)]);
    });
  }

  void _onUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_twoFinger) {
      if (_pointers.length < 2) {
        // 双指会话结束; 剩余单指不继续画, 避免误画, 等待重新按下
        _twoFinger = false;
        _prevMid = null;
        _prevDist = null;
        setState(() {});
      }
      return;
    }
    if (_pointers.isEmpty && _current != null) {
      widget.onCommit(_current!);
      _current = null;
      setState(() {});
    }
  }

  void _updateTwoFingerBase() {
    final pts = _pointers.values.take(2).toList();
    if (pts.length < 2) return;
    _prevMid = (pts[0] + pts[1]) / 2;
    _prevDist = (pts[0] - pts[1]).distance;
  }

  /// 双指增量变换: 中点位移 → 平移, 距离比 → 以中点为焦点缩放
  void _applyTwoFingerTransform() {
    final pts = _pointers.values.take(2).toList();
    if (pts.length < 2 || _prevMid == null || _prevDist == null) {
      _updateTwoFingerBase();
      return;
    }
    final mid = (pts[0] + pts[1]) / 2;
    final dist = (pts[0] - pts[1]).distance;
    final m = widget.transform.value;
    final s = m.getMaxScaleOnAxis();
    if (s <= 0 || dist <= 0 || _prevDist! <= 0) {
      _prevMid = mid;
      _prevDist = dist;
      return;
    }
    final t = m.getTranslation();
    // 平移: 画布坐标位移 × 缩放 → 视口坐标位移
    final tx = t.x + (mid.dx - _prevMid!.dx) * s;
    final ty = t.y + (mid.dy - _prevMid!.dy) * s;
    // 以双指中点 (换算到视口坐标) 为焦点缩放, 保持中点下的画布点不动
    final fx = mid.dx * s + tx;
    final fy = mid.dy * s + ty;
    final sNew =
        (s * dist / _prevDist!).clamp(widget.minZoom, widget.maxZoom).toDouble();
    final ntx = fx - (fx - tx) * (sNew / s);
    final nty = fy - (fy - ty) * (sNew / s);
    widget.transform.value = Matrix4.identity()
      ..translateByDouble(ntx, nty, 0, 1)
      ..scaleByDouble(sNew, sNew, sNew, 1);
    _prevMid = mid;
    _prevDist = dist;
  }

  @override
  Widget build(BuildContext context) {
    final strokes = [...widget.committed];
    if (_current != null) strokes.add(_current!);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: CustomPaint(
        size: Size(widget.canvasWidth, widget.canvasHeight),
        painter: DoodlePainter(
          strokes: strokes,
          width: widget.canvasWidth,
          height: widget.canvasHeight,
        ),
      ),
    );
  }
}

/// 文本内容 + 字号弹窗
///
/// 返回 (文本, 字号); 取消返回 null。controller 在自身 dispose 中释放,
/// 时机为路由完全移除之后 (晚于退场动画), 安全。
class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String? initialText;
  final double initialFontSize;

  const _TextPromptDialog({
    required this.title,
    this.initialText,
    required this.initialFontSize,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _textCtrl;
  late final TextEditingController _sizeCtrl;

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.initialText ?? '');
    _sizeCtrl =
        TextEditingController(text: widget.initialFontSize.toString());
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _sizeCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final size = double.tryParse(_sizeCtrl.text.trim()) ?? widget.initialFontSize;
    Navigator.of(context).pop((_textCtrl.text, size));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.initialText == null;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _textCtrl,
            maxLines: 4,
            autofocus: isNew,
            decoration: const InputDecoration(hintText: '输入文本'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _sizeCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '字号'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: Text(isNew ? '添加' : '保存')),
      ],
    );
  }
}

/// 涂鸦编辑路由
class _DoodleRoute extends StatelessWidget {
  final List<DoodleStroke> initialStrokes;
  final EditorBackground initialBackground;
  const _DoodleRoute({
    this.initialStrokes = const [],
    this.initialBackground = const EditorBackground(),
  });

  @override
  Widget build(BuildContext context) {
    final editorKey = GlobalKey<DoodleEditorState>();
    final editor = DoodleEditor(
      key: editorKey,
      initialStrokes: initialStrokes,
      initialBackground: initialBackground,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('涂鸦编辑器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存涂鸦',
            onPressed: () =>
                Navigator.of(context).pop(editorKey.currentState?.snapshot()),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: editor,
      ),
    );
  }
}
