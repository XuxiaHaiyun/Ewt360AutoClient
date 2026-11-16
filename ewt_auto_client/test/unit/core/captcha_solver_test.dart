/// 滑块验证码缺口检测单元测试 (离线, 合成图像)
///
/// 用 `image` 包合成"背景图 + 拼图块", 验证:
///   - [CaptchaSolver.locateGap] 能在合成图上定位缺口 x 坐标
///   - [CaptchaSolver.findPieceInitialX] 能返回拼图块初始位置
///
/// 合成图可控 (缺口位置已知), 避免依赖真实验证码图片资源。
library;

import 'dart:typed_data';

import 'package:ewt_auto_client/core/captcha/captcha_solver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 生成带缺口的验证码背景 (300x144 JPEG)
/// [gapX]/[gapY] 为缺口矩形左上角坐标, 缺口 40x40 深色块。
///
/// 模拟真实验证码: 左侧有"拼图块初始位置" (与拼图块同款带描边),
/// 缺口为纯暗色块 (与带描边的拼图块模板存在差异, 可被 SSD 区分)。
Uint8List _buildBackground({
  int width = 300,
  int height = 144,
  required int gapX,
  required int gapY,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(220, 220, 220)); // 浅灰背景
  // 添加一些随机噪点, 使图像更接近真实 (非纯色)
  for (var i = 0; i < 200; i++) {
    final x = (i * 37) % width;
    final y = (i * 71) % height;
    final gray = 180 + (i % 40);
    image.setPixelRgb(x, y, gray, gray, gray);
  }
  // 拼图块初始位置 (最左侧, 与拼图块模板完全对齐: 白描边 8..52 + 深块 10..50)
  // 模板 SSD 精确匹配 (≈0), 确保 findPieceInitialX 定位到初始位置而非缺口
  img.fillRect(
    image,
    x1: 8,
    y1: gapY - 2,
    x2: 52,
    y2: gapY + 42,
    color: img.ColorRgb8(255, 255, 255),
  );
  img.fillRect(
    image,
    x1: 10,
    y1: gapY,
    x2: 50,
    y2: gapY + 40,
    color: img.ColorRgb8(60, 60, 60),
  );
  // 缺口: 40x40 暗色条纹纹理 (深浅交替, 与拼图块模板明显不同, 供 SSD 区分)
  for (var row = 0; row < 40; row++) {
    final stripe = (row ~/ 5) % 2 == 0 ? 60 : 120; // 5px 横向条纹
    for (var col = 0; col < 40; col++) {
      image.setPixelRgb(gapX + col, gapY + row, stripe, stripe, stripe);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// 生成拼图块 (60x60 PNG, 透明背景 + 40x40 深色块 + 白色描边)
///
/// 真实拼图块带描边; 描边使模板与"纯色缺口"存在 SSD 差异,
/// 从而 findPieceInitialX 能正确区分初始位置与缺口。
Uint8List _buildPiece() {
  final image = img.Image(width: 60, height: 60, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0)); // 全透明
  // 白色描边 (2px)
  img.fillRect(
    image,
    x1: 8,
    y1: 8,
    x2: 52,
    y2: 52,
    color: img.ColorRgba8(255, 255, 255, 255),
  );
  // 内部深色块
  img.fillRect(
    image,
    x1: 10,
    y1: 10,
    x2: 50,
    y2: 50,
    color: img.ColorRgba8(60, 60, 60, 255),
  );
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  const gapX = 140;
  const gapY = 40;
  final bgBytes = _buildBackground(gapX: gapX, gapY: gapY);
  final pieceBytes = _buildPiece();

  group('CaptchaSolver.locateGap', () {
    test('能在合成图上定位缺口 x 坐标 (误差 ±30)', () {
      final bg = img.decodeJpg(bgBytes)!;
      final piece = img.decodePng(pieceBytes)!;
      final initX = CaptchaSolver.findPieceInitialX(bg, piece, gapY);
      // ignore: avoid_print
      print('DEBUG[140] pieceInitialX=$initX');
      final result = CaptchaSolver.locateGap(
        bgBytes,
        pieceBytes,
        gapY, // yTrack: 缺口矩形顶部 y (对齐服务端 pieceY 语义)
      );
      // ignore: avoid_print
      print('DEBUG[140] locateGap -> x=${result.x}, y=${result.y}, conf=${result.conf}');
      expect(result.x, closeTo(gapX, 30),
          reason: '缺口应在 x=$gapX 附近');
      expect(result.conf, greaterThan(0));
    });

    test('缺口位于左侧时也能定位', () {
      const leftX = 30;
      final bg = img.decodeJpg(_buildBackground(gapX: leftX, gapY: gapY))!;
      final piece = img.decodePng(pieceBytes)!;
      final initX = CaptchaSolver.findPieceInitialX(bg, piece, gapY);
      // ignore: avoid_print
      print('DEBUG[30] pieceInitialX=$initX');
      final result = CaptchaSolver.locateGap(
        img.encodeJpg(bg),
        pieceBytes,
        gapY,
      );
      // ignore: avoid_print
      print('locateGap(left) -> x=${result.x}, conf=${result.conf}');
      expect(result.x, closeTo(leftX, 30));
    });

    test('非法图片抛异常', () {
      expect(
        () => CaptchaSolver.locateGap(
          Uint8List.fromList([1, 2, 3]),
          pieceBytes,
          50,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('CaptchaSolver.findPieceInitialX', () {
    test('返回拼图块在背景上的初始 x', () {
      final bg = img.decodeJpg(bgBytes)!;
      final piece = img.decodePng(pieceBytes)!;
      final x = CaptchaSolver.findPieceInitialX(bg, piece, gapY + 20);
      // 初始位置应明显小于缺口位置 (拼图滑块通常在左侧)
      expect(x, isNotNull);
      expect(x, lessThan(gapX + 10));
    });
  });
}
