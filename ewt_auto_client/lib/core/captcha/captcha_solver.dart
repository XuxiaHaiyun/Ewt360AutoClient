/// 滑块缺口检测算法: 多特征融合评分 (暗度差/均匀度/SSD) 定位缺口,
/// 带抛物线精修, 失败时降级为暗区检测; 还原 Python captcha_solver.py 逻辑。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 滑块缺口检测算法
///
/// 还原 Python: core/captcha_solver.py 的核心逻辑
/// 主路径: locate_gap_rectified（多特征融合）
/// 降级路径: 边缘/阴影检测
class CaptchaSolver {
  /// 预测缺口 x 坐标（图片坐标系）
  ///
  /// 对应 Python: locate_gap_rectified + _template_locate
  /// [bgBytes] 背景图 JPEG bytes (300×144)
  /// [pieceBytes] 滑块拼图块 PNG bytes (带 alpha 通道)
  /// [yTrack] 服务端返回的 y 坐标
  /// 返回 (x, y, confidence)
  static ({int x, int y, double conf}) locateGap(
    Uint8List bgBytes,
    Uint8List pieceBytes,
    int yTrack,
  ) {
    final bg = img.decodeJpg(bgBytes);
    final piece = img.decodePng(pieceBytes);

    if (bg == null || piece == null) {
      throw Exception('无法解码验证码图片');
    }

    // 尝试精确路径：locate_gap_rectified
    final result = _locateGapRectified(bg, piece, yTrack);
    if (result != null) {
      return result;
    }

    // 降级：简单暗区检测
    final fallbackX = _fallbackDetect(bg, piece, yTrack);
    return (x: fallbackX, y: yTrack, conf: 0.1);
  }

  /// 找到拼图块在背景上的初始位置（模板匹配 SSD 最小点）
  ///
  /// 对应 Python: solve_slide_captcha_smart 中的 piece_initial_x 计算
  static int? findPieceInitialX(
    img.Image bg,
    img.Image piece,
    int yTrack,
  ) {
    final arr = _extractPieceTemplate(piece);
    if (arr == null) return null;

    final (templ, mask, tw, th) = arr;
    final H = bg.height;
    final W = bg.width;
    if (th >= H || tw >= W) return null;

    double bestSsd = double.infinity;
    int bestX = 0;

    // 在 yTrack ±5 范围内搜索
    final yStart = math.max(0, yTrack - 5);
    final yEnd = math.min(H - th, yTrack + 6);

    for (int yy = yStart; yy < yEnd; yy++) {
      for (int xx = 0; xx <= W - tw; xx++) {
        double ssd = 0;
        for (int py = 0; py < th; py++) {
          for (int px = 0; px < tw; px++) {
            if (!mask[py][px]) continue;
            final bgP = bg.getPixel(xx + px, yy + py);
            final tP = templ[py][px];
            final dr = bgP.r - tP[0];
            final dg = bgP.g - tP[1];
            final db = bgP.b - tP[2];
            ssd += dr * dr + dg * dg + db * db;
          }
        }
        if (ssd < bestSsd) {
          bestSsd = ssd;
          bestX = xx;
        }
      }
    }

    return bestX;
  }

  /// 改进型缺口定位（多特征融合）
  ///
  /// 对应 Python: locate_gap_rectified
  /// 核心：缺口是「均匀暗色矩形」
  /// 评分 = 暗度差/30 - 内部均值/200 - 方差/10000 + SSD≠piece
  static ({int x, int y, double conf})? _locateGapRectified(
    img.Image bg,
    img.Image piece,
    int yTrack,
  ) {
    final arr = _extractPieceTemplate(piece);
    if (arr == null) return null;

    final (templ, mask, tw, th) = arr;
    final H = bg.height;
    final W = bg.width;
    if (th >= H || tw >= W) return null;

    // 找拼图块初始位置
    final pieceInitialX = findPieceInitialX(bg, piece, yTrack);

    // 预计算灰度图
    final gray = _toGray(bg);

    int yt = yTrack;
    if (yt + th > H) yt = math.max(0, H - th);

    const ring = 6;

    // 逐 x 计分
    double bestScore = -double.infinity;
    int bestX = 0;
    double bestDiff = 0;
    double bestMean = 0;
    double bestVar = 0;

    // 存储 top 分数用于抛物线精修
    final scores = <(double, int)>[];

    for (int xx = 3; xx <= W - tw - 3; xx++) {
      // 排除拼图块初始位置 ±8
      if (pieceInitialX != null && (xx - pieceInitialX).abs() < 8) continue;

      // 矩形暗度/均匀度
      double rectSum = 0;
      double rectSqSum = 0;
      int rectCount = 0;
      for (int py = 0; py < th; py++) {
        for (int px = 0; px < tw; px++) {
          final g = gray[yt + py][xx + px];
          rectSum += g;
          rectSqSum += g * g;
          rectCount++;
        }
      }
      final rectMean = rectSum / rectCount;
      final rectVar = rectSqSum / rectCount - rectMean * rectMean;

      // 外环均值
      final y0m = math.max(0, yt - ring);
      final y1m = math.min(H, yt + th + ring);
      final x0m = math.max(0, xx - ring);
      final x1m = math.min(W, xx + tw + ring);

      double outerSum = 0;
      int outerCount = 0;
      for (int oy = y0m; oy < y1m; oy++) {
        for (int ox = x0m; ox < x1m; ox++) {
          // 排除内部矩形
          if (oy >= yt && oy < yt + th && ox >= xx && ox < xx + tw) continue;
          outerSum += gray[oy][ox];
          outerCount++;
        }
      }
      final extMean = outerCount > 0 ? outerSum / outerCount : 128.0;
      final diff = extMean - rectMean;

      // jigsaw mask 内 SSD（与 piece 不同 → 高）
      double ssd = 0;
      for (int py = 0; py < th; py++) {
        for (int px = 0; px < tw; px++) {
          if (!mask[py][px]) continue;
          final bgP = bg.getPixel(xx + px, yt + py);
          final tP = templ[py][px];
          final dr = bgP.r - tP[0];
          final dg = bgP.g - tP[1];
          final db = bgP.b - tP[2];
          ssd += dr * dr + dg * dg + db * db;
        }
      }

      // 综合评分（还原 Python 公式）
      final score = diff / 30.0 -
          rectMean / 200.0 -
          rectVar / 10000.0 +
          ssd / 1e7 * 0.08;

      scores.add((score, xx));
      if (score > bestScore) {
        bestScore = score;
        bestX = xx;
        bestDiff = diff;
        bestMean = rectMean;
        bestVar = rectVar;
      }
    }

    if (scores.isEmpty) return null;

    // 抛物线精修
    int refinedX = bestX;
    final nearby = scores
        .where((s) => (s.$2 - bestX).abs() <= 2)
        .toList()
      ..sort((a, b) => b.$1.compareTo(a.$1));

    if (nearby.length >= 3) {
      final tri = nearby.take(3).map((s) => s.$2).toList()..sort();
      if (tri.length >= 3) {
        final x0 = tri[0], x1 = tri[1], x2 = tri[2];
        final s0 = nearby.firstWhere((s) => s.$2 == x0).$1;
        final s1 = nearby.firstWhere((s) => s.$2 == x1).$1;
        final s2 = nearby.firstWhere((s) => s.$2 == x2).$1;
        final denom = s0 - 2 * s1 + s2;
        if (denom.abs() > 1e-9) {
          final sub = x1 + 0.5 * (s0 - s2) / denom;
          refinedX = sub.round().clamp(2, W - tw - 2);
        }
      }
    }

    final conf = (bestDiff / 60.0 - bestMean / 300.0 - bestVar / 12000.0)
        .clamp(0.0, 1.0);

    return (x: refinedX, y: yt, conf: conf);
  }

  /// 降级：简单暗区检测
  static int _fallbackDetect(img.Image bg, img.Image piece, int yTrack) {
    final gray = _toGray(bg);
    final pw = piece.width;
    final ph = piece.height;
    final W = bg.width;
    final H = bg.height;
    final yt = yTrack.clamp(0, H - ph);

    double minBrightness = double.infinity;
    int bestX = W ~/ 2;

    for (int xx = 3; xx <= W - pw - 3; xx++) {
      double sum = 0;
      int count = 0;
      for (int py = 0; py < ph; py += 2) {
        for (int px = 0; px < pw; px += 2) {
          sum += gray[yt + py][xx + px];
          count++;
        }
      }
      final avg = sum / count;
      if (avg < minBrightness) {
        minBrightness = avg;
        bestX = xx;
      }
    }

    return bestX;
  }

  /// 从拼图块 PNG 提取模板（裁剪到 alpha bbox）
  ///
  /// 返回 (templ RGB, mask bool, width, height) 或 null
  static (List<List<List<double>>>, List<List<bool>>, int, int)?
      _extractPieceTemplate(img.Image piece) {
    final w = piece.width;
    final h = piece.height;

    // 找 alpha bbox
    int minX = w, maxX = 0, minY = h, maxY = 0;
    bool found = false;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (piece.getPixel(x, y).a > 16) {
          found = true;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (!found) return null;

    final tw = maxX - minX + 1;
    final th = maxY - minY + 1;
    if (tw < 5 || th < 5) return null;

    final templ = List.generate(
      th,
      (py) => List.generate(tw, (px) {
        final p = piece.getPixel(minX + px, minY + py);
        return [p.r.toDouble(), p.g.toDouble(), p.b.toDouble()];
      }),
    );

    final mask = List.generate(
      th,
      (py) => List.generate(tw, (px) {
        return piece.getPixel(minX + px, minY + py).a > 16;
      }),
    );

    return (templ, mask, tw, th);
  }

  /// RGB → 灰度图
  static List<List<double>> _toGray(img.Image image) {
    return List.generate(
      image.height,
      (y) => List.generate(image.width, (x) {
        final p = image.getPixel(x, y);
        return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }),
    );
  }
}
