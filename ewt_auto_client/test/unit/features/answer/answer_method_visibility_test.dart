/// 风控对"试题答案"方案显示的控制 (answer_method.* 特性键)
///
/// 覆盖 AnswerConfigPage.visibleMethods 的过滤语义:
///   - 配置缺失 (未注册) = 放行 (全部可见)
///   - 显式 false = 隐藏
///   - 全部隐藏 = 空列表 (页面收起方案选择区, 服务端回退全链)
///
/// 依赖 RiskControlConstants.kRiskControlEnabled = true (发布态), 关闭时跳过。
library;

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/risk_control/risk_control_config.dart';
import 'package:ewt_auto_client/core/risk_control/risk_control_constants.dart';
import 'package:ewt_auto_client/features/answer/presentation/pages/answer_config_page.dart';
import 'package:flutter_test/flutter_test.dart';

RiskControlConfig _config(Map<String, bool> methods) => RiskControlConfig(
  features: {
    'answer_method': {
      'auto': methods['auto'] ?? true,
      'direct': methods['direct'] ?? true,
      'escalation': methods['escalation'] ?? true,
      'favorites': methods['favorites'] ?? true,
      'download': methods['download'] ?? true,
    },
  },
);

void main() {
  final gateEnabled = RiskControlConstants.kRiskControlEnabled;

  setUp(() {
    if (getIt.isRegistered<RiskControlConfig>()) {
      getIt.unregister<RiskControlConfig>();
    }
  });

  tearDown(() {
    if (getIt.isRegistered<RiskControlConfig>()) {
      getIt.unregister<RiskControlConfig>();
    }
  });

  test('配置缺失 (未注册) = 放行, 全部方案可见', () {
    expect(
      AnswerConfigPage.visibleMethods().map((m) => m.value).toList(),
      ['auto', 'direct', 'escalation', 'favorites', 'download'],
      skip: !gateEnabled ? 'kRiskControlEnabled=false, 门控整体放行' : null,
    );
  });

  test('显式 false 隐藏对应方案 (escalation/download)', () {
    getIt.registerSingleton<RiskControlConfig>(
      _config({'escalation': false, 'download': false}),
    );
    expect(
      AnswerConfigPage.visibleMethods().map((m) => m.value).toList(),
      ['auto', 'direct', 'favorites'],
      skip: !gateEnabled ? 'kRiskControlEnabled=false, 门控整体放行' : null,
    );
  });

  test('全部隐藏 = 空列表 (页面收起方案选择区)', () {
    getIt.registerSingleton<RiskControlConfig>(
      _config({
        'auto': false,
        'direct': false,
        'escalation': false,
        'favorites': false,
        'download': false,
      }),
    );
    expect(
      AnswerConfigPage.visibleMethods(),
      isEmpty,
      skip: !gateEnabled ? 'kRiskControlEnabled=false, 门控整体放行' : null,
    );
  });
}
