/// 滑块验证对话框：默认 3s 倒计时内自动求解，失败自动切换手动拖拽模式。
/// show 返回 captchaToken（成功）或 null（取消/失败）。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'package:ewt_auto_client/core/captcha/captcha_models.dart';
import 'package:ewt_auto_client/core/captcha/captcha_service.dart';

/// 滑块验证对话框
///
/// 默认自动求解，失败后切换手动拖拽模式
class CaptchaDialog extends StatefulWidget {
  final String? bizCode;
  const CaptchaDialog({super.key, this.bizCode});

  /// 显示滑块验证对话框，返回 captchaToken（成功）或 null（取消/失败）
  static Future<String?> show(BuildContext context, {String? bizCode}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CaptchaDialog(bizCode: bizCode),
    );
  }

  @override
  State<CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<CaptchaDialog> {
  late final CaptchaService _service;

  CaptchaData? _captchaData;
  ui.Image? _bgImage;
  ui.Image? _pieceImage;

  bool _loading = true;
  bool _verifying = false;
  String? _error;

  /// true = 自动模式（默认），false = 手动模式
  bool _autoMode = true;

  /// 自动求解倒计时（秒）
  int _countdown = 3;
  Timer? _countdownTimer;
  bool _autoSolveStarted = false;

  double _sliderValue = 0;
  bool _dragging = false;

  static const double displayWidth = 300;
  static const double displayHeight = 144;

  @override
  void initState() {
    super.initState();
    _service = CaptchaService(bizCode: widget.bizCode);
    // 先加载图片供手动模式使用，同时启动 3s 倒计时
    _loadCaptcha();
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _bgImage?.dispose();
    _pieceImage?.dispose();
    super.dispose();
  }

  /// 3 秒倒计时后自动求解
  void _startCountdown() {
    _countdown = 3;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_countdown <= 1) {
        _countdownTimer?.cancel();
        _autoSolve();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  /// 自动求解
  Future<void> _autoSolve() async {
    if (_autoSolveStarted) return;
    _autoSolveStarted = true;
    _countdownTimer?.cancel();

    setState(() {
      _autoMode = true;
      _verifying = true;
      _error = null;
    });

    try {
      final token = await _service.solveAutomatically();
      if (!mounted) return;
      Navigator.of(context).pop(token);
    } catch (e) {
      if (!mounted) return;
      // 自动失败，切换到手动模式
      setState(() {
        _verifying = false;
        _autoMode = false;
        _autoSolveStarted = false;
        _error = '自动识别失败，请手动拖动滑块';
      });
    }
  }

  /// 加载验证码图片（手动模式用）
  Future<void> _loadCaptcha() async {
    setState(() {
      _loading = true;
      _sliderValue = 0;
      if (_autoMode) _error = null;
    });

    try {
      final data = await _service.getCaptcha();
      final bgUi = await _decodeImage(data.backgroundImage);
      final pieceUi = await _decodeImage(data.pieceImage);

      if (!mounted) return;

      // 释放旧图片
      _bgImage?.dispose();
      _pieceImage?.dispose();

      setState(() {
        _captchaData = data;
        _bgImage = bgUi;
        _pieceImage = pieceUi;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载验证码失败: $e';
      });
    }
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('图片解码失败');

    final rgba = decoded.convert(numChannels: 4);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList(rgba.toUint8List()),
      rgba.width,
      rgba.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void _onSliderChanged(double value) {
    setState(() => _sliderValue = value);
  }

  Future<void> _onSliderEnd(double value) async {
    if (_captchaData == null) return;

    setState(() => _verifying = true);

    try {
      // 服务器期望原始图片像素坐标
      final originalWidth = _bgImage?.width.toDouble() ?? displayWidth;
      final x = (value * originalWidth).round();
      final y = _captchaData!.pieceY;

      final result = await _service.verify(
        sessionId: _captchaData!.sessionId,
        x: x,
        y: y,
      );

      if (!mounted) return;

      if (result.success) {
        final token = result.captchaToken.isNotEmpty
            ? result.captchaToken
            : _captchaData!.captchaToken;
        Navigator.of(context).pop(token);
      } else {
        setState(() {
          _verifying = false;
          _sliderValue = 0;
          _error = '验证失败，请重试';
        });
        await _loadCaptcha();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = '验证出错: $e';
      });
    }
  }

  /// 切换模式按钮
  void _toggleMode() {
    if (_autoMode) {
      // 切到手动：取消倒计时
      _countdownTimer?.cancel();
      setState(() {
        _autoMode = false;
        _autoSolveStarted = false;
        _error = null;
      });
    } else {
      // 切到自动：重新启动自动求解
      _autoSolveStarted = false;
      _autoSolve();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          const Text('安全验证'),
        ],
      ),
      content: SizedBox(
        width: displayWidth + 48,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 倒计时提示
            if (_autoMode && !_autoSolveStarted) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${_countdown}s 后自动验证',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            // 主内容区
            if (_autoMode && _autoSolveStarted)
              _buildAutoArea(theme)
            else
              _buildManualArea(theme),
            const SizedBox(height: 12),
            // 操作按钮
            _buildActions(theme),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
      ],
    );
  }

  /// 自动模式：显示进度
  Widget _buildAutoArea(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 24),
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          '正在自动识别...',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// 手动模式：图片 + 滑轨（响应式，适应窄窗口）
  Widget _buildManualArea(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : displayWidth;
        // 按原始图片宽高比计算显示高度
        final aspectRatio = _bgImage != null
            ? _bgImage!.height / _bgImage!.width
            : displayHeight / displayWidth;
        final height = width * aspectRatio;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildImageArea(theme, width, height),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
              const SizedBox(height: 8),
            ],
            _buildSlider(theme, width),
          ],
        );
      },
    );
  }

  Widget _buildImageArea(ThemeData theme, double width, double height) {
    if (_loading) {
      return SizedBox(
        width: width,
        height: height,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_bgImage == null || _pieceImage == null) {
      return SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image, size: 48, color: theme.colorScheme.outline),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _loadCaptcha,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _CaptchaPainter(
            bgImage: _bgImage!,
            pieceImage: _pieceImage!,
            pieceX: _sliderValue * width,
            pieceY: (_captchaData?.pieceY ?? 0).toDouble(),
          ),
        ),
      ),
    );
  }

  Widget _buildSlider(ThemeData theme, double width) {
    const handleSize = 44.0;
    final maxLeft = width - handleSize;

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _sliderValue * maxLeft + 22,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(22),
              ),
            ),
          ),
          Center(
            child: Text(
              _verifying ? '验证中...' : '拖动滑块完成验证',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
          Positioned(
            left: _sliderValue * maxLeft,
            child: GestureDetector(
              onHorizontalDragStart: (d) {
                _dragging = true;
              },
              onHorizontalDragUpdate: (d) {
                if (!_dragging) return;
                final newValue =
                    ((_sliderValue * maxLeft + d.delta.dx) / maxLeft)
                        .clamp(0.0, 1.0);
                _onSliderChanged(newValue);
              },
              onHorizontalDragEnd: (_) {
                _dragging = false;
                _onSliderEnd(_sliderValue);
              },
              child: Container(
                width: handleSize,
                height: handleSize,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  _verifying ? Icons.hourglass_top : Icons.arrow_forward,
                  color: theme.colorScheme.onPrimary,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    final inManual = !_autoMode;
    final solving = _autoMode && _autoSolveStarted;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (inManual)
          TextButton.icon(
            onPressed: _loading || _verifying ? null : _loadCaptcha,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('换一张'),
          )
        else
          const SizedBox.shrink(),
        FilledButton.tonalIcon(
          onPressed: solving || _verifying ? null : _toggleMode,
          icon: Icon(
            _autoMode ? Icons.touch_app : Icons.auto_awesome,
            size: 18,
          ),
          label: Text(_autoMode ? '手动验证' : '自动验证'),
        ),
      ],
    );
  }
}

/// 验证码画布绘制器
class _CaptchaPainter extends CustomPainter {
  final ui.Image bgImage;
  final ui.Image pieceImage;
  final double pieceX;
  final double pieceY;

  _CaptchaPainter({
    required this.bgImage,
    required this.pieceImage,
    required this.pieceX,
    required this.pieceY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final bgSrc = Rect.fromLTWH(
      0, 0,
      bgImage.width.toDouble(),
      bgImage.height.toDouble(),
    );
    canvas.drawImageRect(bgImage, bgSrc, bgRect, Paint());

    final scaleX = size.width / bgImage.width;
    final scaleY = size.height / bgImage.height;

    final pieceW = pieceImage.width * scaleX;
    final pieceH = pieceImage.height * scaleY;

    final pieceRect = Rect.fromLTWH(pieceX, pieceY * scaleY, pieceW, pieceH);
    final pieceSrc = Rect.fromLTWH(
      0, 0,
      pieceImage.width.toDouble(),
      pieceImage.height.toDouble(),
    );

    // 阴影
    canvas.save();
    canvas.translate(pieceRect.left + 2, pieceRect.top + 2);
    canvas.drawImageRect(
      pieceImage,
      pieceSrc,
      Rect.fromLTWH(0, 0, pieceW, pieceH),
      Paint()
        ..colorFilter = const ui.ColorFilter.mode(
          Colors.black26,
          ui.BlendMode.srcIn,
        ),
    );
    canvas.restore();

    // 拼图块本体
    canvas.drawImageRect(pieceImage, pieceSrc, pieceRect, Paint());
  }

  @override
  bool shouldRepaint(_CaptchaPainter oldDelegate) {
    return oldDelegate.pieceX != pieceX ||
        oldDelegate.pieceY != pieceY ||
        oldDelegate.bgImage != bgImage ||
        oldDelegate.pieceImage != pieceImage;
  }
}
