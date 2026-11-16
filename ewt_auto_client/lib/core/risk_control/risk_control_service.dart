/// 远程风控配置加载: 独立 Dio 拉取 sharechain 页面 → 剥离 HTML 标签 →
/// 提取标记间密文并解密 → 解析为 RiskControlConfig; 任意失败抛异常 (fail-closed)。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'risk_control_config.dart';
import 'risk_control_constants.dart';
import 'risk_control_crypto.dart';

/// 远程风控配置加载服务
///
/// 拉取 sharechain 页面 HTML -> 去除 HTML 标签 -> 提取标记间密文 -> 解密
/// -> 解析为 [RiskControlConfig]。
///
/// sharechain 页面会将长文本按固定长度分块放入多个 `<div>` 中, 导致密文
/// 被标签打断, 必须先剥离所有 HTML 标签再提取标记间内容。
///
/// 任意步骤失败均抛异常 (fail-closed), 由调用方捕获并弹窗退出。
class RiskControlService {
  RiskControlService._();

  /// Android Chrome UA (sharechain 对非浏览器 UA 可能返回不同页面结构)
  static const String _androidUA =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Mobile Safari/537.36';

  static Future<RiskControlConfig> load() async {
    final dio = Dio(BaseOptions(
      responseType: ResponseType.plain,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      followRedirects: true,
      headers: {
        'User-Agent': _androidUA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    ));
    try {
      final resp = await dio.get<String>(RiskControlConstants.sharechainUrl);
      var body = resp.data ?? '';
      // 剥离所有 HTML 标签 (sharechain 用 <div> 分块包裹长文本)
      body = body.replaceAll(RegExp(r'<[^>]+>'), '');
      final jsonStr = RiskControlCrypto.decrypt(body);
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      return RiskControlConfig.fromJson(map);
    } finally {
      dio.close();
    }
  }
}
