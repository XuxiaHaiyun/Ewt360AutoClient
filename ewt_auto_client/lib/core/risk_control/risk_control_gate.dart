/// 风控功能开关门面: UI 一行调用 isFeatureEnabled('group.item') 判定;
/// 未注册配置或总开关关闭时全部放行, 避免阻塞开发期。
library;

import '../di/injection.dart';
import 'risk_control_config.dart';
import 'risk_control_constants.dart';

/// 风控功能开关门面
///
/// UI 处一行调用 `RiskControlGate.isFeatureEnabled('homework_menu.report')`。
/// 未注册配置时 (开发期未接入风控流程) 放行, 避免阻塞。
class RiskControlGate {
  RiskControlGate._();

  static RiskControlConfig? get maybeConfig {
    if (getIt.isRegistered<RiskControlConfig>()) {
      return getIt<RiskControlConfig>();
    }
    return null;
  }

  static bool isFeatureEnabled(String dottedKey) {
    // 硬编码总开关关闭 -> 全部放行 (不限制)
    if (!RiskControlConstants.kRiskControlEnabled) return true;
    final config = maybeConfig;
    if (config == null) return true;
    return config.isFeatureEnabled(dottedKey);
  }
}
