/// 应用入口: 初始化 DI/MediaKit/网络日志, 执行风控启动链路 (fail-closed),
/// 并以 MaterialApp.router 装配主题/路由/中文本地化/字体缩放。
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/di/injection.dart';
import 'core/network/dio_client.dart';
import 'core/risk_control/risk_control_boot.dart';
import 'core/risk_control/risk_control_config.dart';
import 'core/risk_control/risk_control_constants.dart';
import 'core/risk_control/risk_control_password_cache.dart';
import 'core/risk_control/risk_control_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/providers/auth_provider.dart';
import 'features/settings/presentation/providers/settings_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // MediaKit (mpv) 不支持 Web 平台, 仅 native 端初始化
  if (!kIsWeb) {
    MediaKit.ensureInitialized();
  }
  configureDependencies();

  // 风控总开关关闭时跳过整个风控启动流程 (不弹窗 / 不退出 / 全部放行)
  if (RiskControlConstants.kRiskControlEnabled) {
    // 远程拉取 sharechain 页面 -> 提取标记 -> 解密 -> 加载
    // fail-closed: 任意失败弹窗后退出, 不降级运行
    RiskControlConfig? rcConfig;
  try {
    rcConfig = await RiskControlService.load();
  } catch (_) {
    await RiskControlBoot.showFatalDialog(
        RiskControlConstants.loadFailMessage);
    RiskControlBoot.terminate();
    return;
  }
  getIt.registerSingleton<RiskControlConfig>(rcConfig);

  // 1) 一键跑路: 整体停用, 弹窗后退出
  if (!rcConfig.isAppEnabled()) {
    await RiskControlBoot.showFatalDialog(rcConfig.disabledMessage);
    RiskControlBoot.terminate();
    return;
  }
  // 2) 启动密码门 (防倒卖/防滥用传播): 密码存于远程加密配置, 可随时远程更改
  //    密码缓存: 远程密码不变时跳过弹窗, 密码改变时重新要求输入
  if (rcConfig.hasStartupPassword) {
    final unchanged = await RiskControlPasswordCache.isUnchanged(rcConfig.startupPassword);
    if (!unchanged) {
      final ok = await RiskControlBoot.showStartupPasswordGate(rcConfig);
      if (!ok) {
        RiskControlBoot.terminate();
        return;
      }
      // 验证通过, 更新本地缓存为当前远程密码哈希
      await RiskControlPasswordCache.markVerified(rcConfig.startupPassword);
    }
  } else {
    // 远程密码被清空, 同步清除本地缓存
    await RiskControlPasswordCache.clear();
  }
  // 3) 过期: 弹窗提示后直接退出, 不进入 App
  if (rcConfig.isExpired()) {
    await RiskControlBoot.showFatalDialog(rcConfig.expiredMessage);
    RiskControlBoot.terminate();
    return;
  }
  } // if (RiskControlConstants.kRiskControlEnabled)

  // 恢复网络日志开关
  final prefs = await SharedPreferences.getInstance();
  final logEnabled = prefs.getBool('settings_networkLog') ?? false;
  DioClient.setLoggingEnabled(logEnabled);

  final container = ProviderContainer();
  getIt.registerSingleton<ProviderContainer>(container);

  runApp(UncontrolledProviderScope(container: container, child: const EwtApp()));
}

class EwtApp extends ConsumerStatefulWidget {
  const EwtApp({super.key});

  @override
  ConsumerState<EwtApp> createState() => _EwtAppState();
}

class _EwtAppState extends ConsumerState<EwtApp> {
  @override
  void initState() {
    super.initState();
    // 启动时恢复上次登录会话
    Future.microtask(() {
      ref.read(authProvider.notifier).tryRestoreSession();
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);

    return MaterialApp.router(
      title: 'EWT Auto Client',
      debugShowCheckedModeBanner: false,
      // 强调色/全局字体/页面过渡动画来自设置页选择, 即时生效
      theme: AppTheme.light(
        settings.accentColor,
        fontFamily: settings.appFontFamily,
        pageTransition: settings.pageTransition,
      ),
      darkTheme: AppTheme.dark(
        settings.accentColor,
        fontFamily: settings.appFontFamily,
        pageTransition: settings.pageTransition,
      ),
      themeMode: settings.themeMode,
      routerConfig: appRouter,
      // 中文本地化: Material 组件 (日期选择器/弹窗按钮/工具提示等) 使用中文
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // 系统大字体缩放限制 (1.0~1.3) × 设置页"界面缩放"系数,
      // 防止小屏/大字体下布局溢出, 同时提供用户可控的界面缩放
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final systemFactor = media.textScaler.scale(1.0).clamp(1.0, 1.3);
        final factor = (systemFactor * settings.uiScale).clamp(0.8, 1.6);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(factor)),
          child: child!,
        );
      },
    );
  }
}
