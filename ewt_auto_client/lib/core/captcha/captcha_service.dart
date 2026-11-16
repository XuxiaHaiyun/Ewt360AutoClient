/// 滑块验证码自动求解服务: 视觉预测缺口 x 后,
/// 先局部 verify 扫描 (±12, step 3), 未命中再全图扫描 (step 4) 兜底,
/// 成功后返回 captchaToken; 另暴露手动验证接口供 UI 使用。
library;

import '../constants/crypto_constants.dart';
import 'captcha_models.dart';
import 'captcha_net.dart';
import 'captcha_solver.dart';

/// 滑块验证服务
///
/// 还原 Python: core/captcha_solver.py solve_slide_captcha_smart 流程
/// 1. GET 验证码
/// 2. 视觉预测缺口 x（locate_gap_rectified）
/// 3. 局部 verify 扫描（pred_x ±12, step 3）
/// 4. 未命中则全图扫描兜底（step 4）
class CaptchaService {
  final CaptchaNet _net;

  CaptchaService({String? bizCode, CaptchaNet? net})
      : _net = net ?? CaptchaNet(bizCode: bizCode ?? CryptoConstants.passwordCaptchaBizCode);

  /// 完整自动求解流程
  ///
  /// 返回验证通过后的 captchaToken
  Future<String> solveAutomatically() async {
    final captcha = await _net.getCaptcha();
    final y = captcha.pieceY;

    // 1) 视觉预测缺口 x
    int? predX;
    try {
      final result = CaptchaSolver.locateGap(
        captcha.backgroundImage,
        captcha.pieceImage,
        y,
      );
      predX = result.x;
    } catch (_) {
      // 视觉失败，直接全图扫描
    }

    // 2) 局部 verify 扫描（pred_x ±12, step 3）
    if (predX != null) {
      final token = await _localVerifyScan(
        sessionId: captcha.sessionId,
        predX: predX,
        y: y,
        half: 12,
        step: 3,
        fallbackToken: captcha.captchaToken,
      );
      if (token != null) return token;
    }

    // 3) 全图扫描兜底（step 4）
    final token = await _fullVerifyScan(
      sessionId: captcha.sessionId,
      y: y,
      step: 4,
      fallbackToken: captcha.captchaToken,
    );
    if (token != null) return token;

    throw Exception('滑块验证自动求解失败');
  }

  /// 局部 verify 扫描
  ///
  /// 对应 Python: confirm_local_verify
  /// 在 pred_x ±half 内以 step 步长扫描，命中后邻域细扫
  Future<String?> _localVerifyScan({
    required String sessionId,
    required int predX,
    required int y,
    required int half,
    required int step,
    required String fallbackToken,
  }) async {
    final lo = (predX - half).clamp(2, 290);
    final hi = (predX + half + 1).clamp(2, 290);

    for (int x = lo; x < hi; x += step) {
      final result = await _net.verify(sessionId: sessionId, x: x, y: y);
      if (result.success) {
        // 命中后邻域细扫（±2）确认最佳点
        final fineToken = await _fineScan(
          sessionId: sessionId,
          hitX: x,
          y: y,
          radius: 2,
        );
        return fineToken ?? result.captchaToken.ifEmpty(fallbackToken);
      }
    }
    return null;
  }

  /// 全图 verify 扫描
  ///
  /// 对应 Python: scan_and_verify（粗扫 step=4，命中后细扫）
  Future<String?> _fullVerifyScan({
    required String sessionId,
    required int y,
    required int step,
    required String fallbackToken,
  }) async {
    for (int x = 0; x < 290; x += step) {
      final result = await _net.verify(sessionId: sessionId, x: x, y: y);
      if (result.success) {
        final fineToken = await _fineScan(
          sessionId: sessionId,
          hitX: x,
          y: y,
          radius: 2,
        );
        return fineToken ?? result.captchaToken.ifEmpty(fallbackToken);
      }
    }
    return null;
  }

  /// 命中后邻域细扫
  ///
  /// 对应 Python: scan_and_verify 中命中后的 fine_radius 循环
  Future<String?> _fineScan({
    required String sessionId,
    required int hitX,
    required int y,
    required int radius,
  }) async {
    String? bestToken;
    for (int dx = -radius; dx <= radius; dx++) {
      final xx = hitX + dx;
      if (xx < 0 || xx >= 290) continue;
      final result = await _net.verify(sessionId: sessionId, x: xx, y: y);
      if (result.success && result.captchaToken.isNotEmpty) {
        bestToken = result.captchaToken;
      }
    }
    return bestToken;
  }

  /// 获取验证码数据（供 UI 手动验证使用）
  Future<CaptchaData> getCaptcha() => _net.getCaptcha();

  /// 手动验证（UI 拖拽后调用）
  Future<CaptchaVerifyResult> verify({
    required String sessionId,
    required int x,
    required int y,
  }) =>
      _net.verify(sessionId: sessionId, x: x, y: y);
}

/// String 扩展：空字符串时返回 fallback
extension _StringIfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
