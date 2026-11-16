/// 应用设置 Riverpod 状态管理：定义 AppSettingsState（主题/强调色/网络/显示/保活等），
/// 并经 SettingsNotifier 持久化到 SharedPreferences，供全局 UI 与网络层读取。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/fonts/font_manager.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/core/network/network_tuning.dart';
import 'package:ewt_auto_client/core/platform/keep_alive_channel.dart';
import 'package:ewt_auto_client/core/platform/windows_keep_alive.dart';
import 'package:ewt_auto_client/core/theme/app_theme.dart';

/// 应用设置状态
class AppSettingsState {
  final ThemeMode themeMode;

  /// 强调色 (M3 种子色)。默认 [AppTheme.defaultSeed]。
  ///
  /// 持久化使用 [AppTheme.accentColorPrefKey] (与设置页/风控启动弹窗共用)，
  /// 加载时经 [AppTheme.seedFromValue] 校验，非法值回退默认。
  final Color accentColor;

  final int requestInterval; // ms
  final bool networkLogEnabled;
  final bool demoMode;

  // ─── 网络: SSL 证书 / HTTP/2 / 连接重试 ───
  /// 禁用 SSL 证书验证 (自签名证书/抓包场景, 安全风险自负)
  final bool disableSslVerify;

  /// 启用 HTTP/2 (与代理/禁用证书验证互斥, 冲突时回退 HTTP/1.1)
  final bool enableHttp2;

  /// 连接失败重试次数 (0 = 不重试)
  final int connectRetryCount;

  /// 连接重试间隔 (ms)
  final int connectRetryIntervalMs;

  // ─── 显示: 悬浮底栏 / 字体管理 / 界面缩放 / 页面过渡动画 ───
  /// 窄屏底部导航悬浮样式 (圆角胶囊 + 投影, 不贴边)
  final bool floatingBottomBar;

  /// 全局显示字体类别: 'default' | 'system' | 'bundled' | 'imported'
  final String appFontKind;

  /// 全局显示字体族名 (system 系统族名 / bundled pubspec family / imported family)
  final String appFontValue;

  /// 已导入字体列表 (字体管理导入, 供全局显示与手写模拟共用)
  final List<ImportedFont> importedFonts;

  /// 界面缩放 (系统字体缩放系数上再乘, 0.8~1.5)
  final double uiScale;

  /// 页面过渡动画: 'native' (平台默认) | 'fade' | 'slide' | 'none'
  final String pageTransition;

  /// 当前全局显示字体族名 (default 时 null = 跟随主题默认)
  String? get appFontFamily =>
      appFontKind == 'default' ? null : appFontValue;

  /// 主页导航栏显示的 TAB (路由路径列表, 如 ['/home', '/tasks'])
  ///
  /// '设置' TAB 固定显示不可隐藏, 不在此列表约束。
  final List<String> visibleTabs;

  /// 高级：会员鉴权越权（contentType=3 绕过会员门领取播放凭证）
  final bool memberAuthBypass;

  /// 高级：周培优班级越权（classId 置空拉取学校全部周培优班级）
  final bool weekendClassBypass;

  /// 高级：签到（开关即执行，打开时用当前登录账号签到）
  final bool checkinRaceEnabled;

  /// 高级：显示进度上报配置页的"任意用户进度注入"开关
  ///
  /// 仅控制功能入口的显示/隐藏 (默认隐藏); 已保存的上报配置不受影响。
  final bool showReportInject;

  /// 保活：保持屏幕常亮
  final bool keepScreenOn;

  /// 保活：KeepLiveService 框架总开关
  final bool keepAliveEnabled;

  // ─── KeepLiveService 框架选项 ───
  /// 各策略开关 (键与原生 FwConfigExt.FwOptionKeys 一一对应),
  /// 默认值见 [fwOptionDefaults], UI 目录见 settings_page 的 _fwOptionGroups。
  final Map<String, bool> fwOptions;

  /// 侵袭等级: 0=LOW 1=MEDIUM 2=HIGH
  final int fwAggressiveLevel;

  /// 框架选项默认值 (核心策略默认开启, 侵入性强/需敏感权限的默认关闭)
  static const Map<String, bool> fwOptionDefaults = {
    'mediaSession': true,
    'scheduledWakeup': true,
    'accountSync': true,
    'systemBroadcast': true,
    'bluetoothBroadcast': true,
    'silentAudio': false,
    'mediaButtonReceiver': false,
    'usbBroadcast': false,
    'nfcBroadcast': false,
    'mediaMountBroadcast': false,
    'mediaContentObserver': false,
    'contactsContentObserver': false,
    'smsContentObserver': false,
    'settingsContentObserver': false,
    'fileObserver': false,
    'dualProcess': false,
    'nativeDaemon': false,
    'nativeSocket': false,
    'forceStopResistance': false,
    'onePixel': false,
    'lockScreenActivity': false,
    'floatWindow': false,
    'dreamService': false,
    'tileService': false,
    'widget': false,
    'deviceAdmin': false,
    'vpnService': false,
    'companionDevice': false,
    'callStyleNotification': false,
    'mediaSessionNotification': false,
  };

  /// 保活 (Windows)：提高进程优先级
  final bool windowsHighPriority;

  /// 保活 (Windows)：阻止系统自动休眠
  final bool windowsPreventSleep;

  const AppSettingsState({
    this.themeMode = ThemeMode.system,
    this.accentColor = AppTheme.defaultSeed,
    this.requestInterval = 500,
    this.networkLogEnabled = false,
    this.demoMode = false,
    this.disableSslVerify = false,
    this.enableHttp2 = false,
    this.connectRetryCount = 0,
    this.connectRetryIntervalMs = 1000,
    this.floatingBottomBar = false,
    this.appFontKind = 'default',
    this.appFontValue = '',
    this.importedFonts = const [],
    this.uiScale = 1.0,
    this.pageTransition = 'native',
    this.visibleTabs = const ['/home', '/tasks', '/weekend'],
    this.memberAuthBypass = false,
    this.weekendClassBypass = false,
    this.checkinRaceEnabled = false,
    this.showReportInject = false,
    this.keepScreenOn = false,
    this.keepAliveEnabled = false,
    this.fwOptions = fwOptionDefaults,
    this.fwAggressiveLevel = 1,
    this.windowsHighPriority = false,
    this.windowsPreventSleep = false,
  });

  AppSettingsState copyWith({
    ThemeMode? themeMode,
    Color? accentColor,
    int? requestInterval,
    bool? networkLogEnabled,
    bool? demoMode,
    bool? disableSslVerify,
    bool? enableHttp2,
    int? connectRetryCount,
    int? connectRetryIntervalMs,
    bool? floatingBottomBar,
    String? appFontKind,
    String? appFontValue,
    List<ImportedFont>? importedFonts,
    double? uiScale,
    String? pageTransition,
    List<String>? visibleTabs,
    bool? memberAuthBypass,
    bool? weekendClassBypass,
    bool? checkinRaceEnabled,
    bool? showReportInject,
    bool? keepScreenOn,
    bool? keepAliveEnabled,
    Map<String, bool>? fwOptions,
    int? fwAggressiveLevel,
    bool? windowsHighPriority,
    bool? windowsPreventSleep,
  }) {
    return AppSettingsState(
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      requestInterval: requestInterval ?? this.requestInterval,
      networkLogEnabled: networkLogEnabled ?? this.networkLogEnabled,
      demoMode: demoMode ?? this.demoMode,
      disableSslVerify: disableSslVerify ?? this.disableSslVerify,
      enableHttp2: enableHttp2 ?? this.enableHttp2,
      connectRetryCount: connectRetryCount ?? this.connectRetryCount,
      connectRetryIntervalMs:
          connectRetryIntervalMs ?? this.connectRetryIntervalMs,
      floatingBottomBar: floatingBottomBar ?? this.floatingBottomBar,
      appFontKind: appFontKind ?? this.appFontKind,
      appFontValue: appFontValue ?? this.appFontValue,
      importedFonts: importedFonts ?? this.importedFonts,
      uiScale: uiScale ?? this.uiScale,
      pageTransition: pageTransition ?? this.pageTransition,
      visibleTabs: visibleTabs ?? this.visibleTabs,
      memberAuthBypass: memberAuthBypass ?? this.memberAuthBypass,
      weekendClassBypass: weekendClassBypass ?? this.weekendClassBypass,
      checkinRaceEnabled: checkinRaceEnabled ?? this.checkinRaceEnabled,
      showReportInject: showReportInject ?? this.showReportInject,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      keepAliveEnabled: keepAliveEnabled ?? this.keepAliveEnabled,
      fwOptions: fwOptions ?? this.fwOptions,
      fwAggressiveLevel: fwAggressiveLevel ?? this.fwAggressiveLevel,
      windowsHighPriority: windowsHighPriority ?? this.windowsHighPriority,
      windowsPreventSleep: windowsPreventSleep ?? this.windowsPreventSleep,
    );
  }

  /// 演示模式下遮蔽敏感信息（每个字符替换为*）
  String mask(String? text) {
    if (!demoMode) return text ?? '-';
    if (text == null || text.isEmpty || text == '-') return text ?? '-';
    return '*' * text.length;
  }
}

/// 设置 Notifier（带 SharedPreferences 持久化）
class AppSettingsNotifier extends StateNotifier<AppSettingsState> {
  static const _prefix = 'settings_';

  AppSettingsNotifier() : super(const AppSettingsState()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // 恢复当前选中的导入字体 (FontLoader 注册) —— 先于首次 state 设置,
    // 保证全局显示字体在首帧前可用 (全局显示/手写模拟共用)
    final fontKind = prefs.getString('${_prefix}appFontKind') ?? 'default';
    if (fontKind == 'imported') {
      final fontValue = prefs.getString('${_prefix}appFontValue') ?? '';
      if (fontValue.isNotEmpty) {
        for (final f in _decodeImportedFonts(
          prefs.getString('${_prefix}importedFonts'),
        )) {
          if (f.family == fontValue) {
            await FontManager.registerFamily(f.family, f.path);
            break;
          }
        }
      }
    }
    final themeModeIndex = prefs.getInt('${_prefix}themeMode') ?? 0;
    state = state.copyWith(
      themeMode: ThemeMode.values[themeModeIndex.clamp(0, 2)],
      accentColor: AppTheme.seedFromValue(
        prefs.getInt(AppTheme.accentColorPrefKey),
      ),
      requestInterval: prefs.getInt('${_prefix}requestInterval') ?? 500,
      networkLogEnabled: prefs.getBool('${_prefix}networkLog') ?? false,
      demoMode: prefs.getBool('${_prefix}demoMode') ?? false,
      disableSslVerify: prefs.getBool('${_prefix}disableSslVerify') ?? false,
      enableHttp2: prefs.getBool('${_prefix}enableHttp2') ?? false,
      connectRetryCount: prefs.getInt('${_prefix}connectRetryCount') ?? 0,
      connectRetryIntervalMs:
          prefs.getInt('${_prefix}connectRetryIntervalMs') ?? 1000,
      floatingBottomBar: prefs.getBool('${_prefix}floatingBottomBar') ?? false,
      appFontKind: fontKind,
      appFontValue:
          prefs.getString('${_prefix}appFontValue') ?? '',
      importedFonts: _decodeImportedFonts(
        prefs.getString('${_prefix}importedFonts'),
      ),
      uiScale: prefs.getDouble('${_prefix}uiScale') ?? 1.0,
      pageTransition: prefs.getString('${_prefix}pageTransition') ?? 'native',
      visibleTabs:
          prefs.getStringList('${_prefix}visibleTabs') ??
          const ['/home', '/tasks', '/weekend'],
      memberAuthBypass: prefs.getBool('${_prefix}memberAuthBypass') ?? false,
      weekendClassBypass:
          prefs.getBool('${_prefix}weekendClassBypass') ?? false,
      checkinRaceEnabled:
          prefs.getBool('${_prefix}checkinRaceEnabled') ?? false,
      showReportInject: prefs.getBool('${_prefix}showReportInject') ?? false,
      keepScreenOn: prefs.getBool('${_prefix}keepScreenOn') ?? false,
      keepAliveEnabled: prefs.getBool('${_prefix}keepAliveEnabled') ?? false,
      fwOptions: _decodeFwOptions(prefs.getString('${_prefix}fwOptions')),
      fwAggressiveLevel: prefs.getInt('${_prefix}fwAggressiveLevel') ?? 1,
      windowsHighPriority:
          prefs.getBool('${_prefix}windowsHighPriority') ?? false,
      windowsPreventSleep:
          prefs.getBool('${_prefix}windowsPreventSleep') ?? false,
    );
    // 网络: SSL 证书验证 / HTTP/2 / 重试参数同步到运行时 (静态值 + 全局客户端)
    NetworkTuning.update(
      trustAll: state.disableSslVerify,
      http2: state.enableHttp2,
      retryCount: state.connectRetryCount,
      retryIntervalMs: state.connectRetryIntervalMs,
    );
    if (getIt.isRegistered<DioClient>()) {
      getIt<DioClient>()
        ..setTrustAllCerts(state.disableSslVerify)
        ..setHttp2Enabled(state.enableHttp2);
    }
    // 应用已保存的保活设置 (应用冷启动后需重新生效)
    if (state.keepScreenOn) {
      KeepAliveChannel.setKeepScreenOn(true).catchError((_) => false);
    }
    if (Platform.isAndroid) {
      // 保活框架的恢复由 EwtApplication 在进程启动时完成 (早于 Flutter 引擎);
      // 此处兜底: 原生侧未初始化成功时 (如进程被回收后重建) 重新拉起。
      if (state.keepAliveEnabled) {
        KeepAliveChannel.isFrameworkInitialized()
            .then((initialized) {
              if (!initialized) {
                KeepAliveChannel.initFramework(frameworkConfig());
              }
            })
            .catchError((_) => false);
      }
    }
    if (Platform.isWindows) {
      if (state.windowsHighPriority) {
        WindowsKeepAlive.setHighPriority();
      }
      if (state.windowsPreventSleep) {
        WindowsKeepAlive.setPreventSleep();
      }
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}themeMode', state.themeMode.index);
    await prefs.setInt(
      AppTheme.accentColorPrefKey,
      state.accentColor.toARGB32(),
    );
    await prefs.setInt('${_prefix}requestInterval', state.requestInterval);
    await prefs.setBool('${_prefix}networkLog', state.networkLogEnabled);
    await prefs.setBool('${_prefix}demoMode', state.demoMode);
    await prefs.setBool('${_prefix}disableSslVerify', state.disableSslVerify);
    await prefs.setBool('${_prefix}enableHttp2', state.enableHttp2);
    await prefs.setInt('${_prefix}connectRetryCount', state.connectRetryCount);
    await prefs.setInt(
      '${_prefix}connectRetryIntervalMs',
      state.connectRetryIntervalMs,
    );
    await prefs.setBool('${_prefix}floatingBottomBar', state.floatingBottomBar);
    await prefs.setString('${_prefix}appFontKind', state.appFontKind);
    await prefs.setString('${_prefix}appFontValue', state.appFontValue);
    await prefs.setString(
      '${_prefix}importedFonts',
      jsonEncode([for (final f in state.importedFonts) f.toJson()]),
    );
    await prefs.setDouble('${_prefix}uiScale', state.uiScale);
    await prefs.setString('${_prefix}pageTransition', state.pageTransition);
    await prefs.setStringList('${_prefix}visibleTabs', state.visibleTabs);
    await prefs.setBool('${_prefix}memberAuthBypass', state.memberAuthBypass);
    await prefs.setBool(
      '${_prefix}weekendClassBypass',
      state.weekendClassBypass,
    );
    await prefs.setBool(
      '${_prefix}checkinRaceEnabled',
      state.checkinRaceEnabled,
    );
    await prefs.setBool('${_prefix}showReportInject', state.showReportInject);
    await prefs.setBool('${_prefix}keepScreenOn', state.keepScreenOn);
    await prefs.setBool('${_prefix}keepAliveEnabled', state.keepAliveEnabled);
    await prefs.setString('${_prefix}fwOptions', jsonEncode(state.fwOptions));
    await prefs.setInt('${_prefix}fwAggressiveLevel', state.fwAggressiveLevel);
    await prefs.setBool(
      '${_prefix}windowsHighPriority',
      state.windowsHighPriority,
    );
    await prefs.setBool(
      '${_prefix}windowsPreventSleep',
      state.windowsPreventSleep,
    );
  }

  void setThemeMode(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    _persist();
  }

  /// 设置强调色 (M3 种子色，MaterialApp 即时响应)
  void setAccentColor(Color color) {
    state = state.copyWith(accentColor: color);
    _persist();
  }

  void setRequestInterval(int ms) {
    state = state.copyWith(requestInterval: ms.clamp(0, 5000));
    _persist();
  }

  void setNetworkLog(bool enabled) {
    state = state.copyWith(networkLogEnabled: enabled);
    DioClient.setLoggingEnabled(enabled);
    _persist();
  }

  void setDemoMode(bool enabled) {
    state = state.copyWith(demoMode: enabled);
    _persist();
  }

  // ─── 网络: SSL / HTTP/2 / 重试 ───

  /// 禁用 SSL 证书验证 (同步静态值 + 全局客户端重建适配器)
  Future<void> setDisableSslVerify(bool enabled) async {
    state = state.copyWith(disableSslVerify: enabled);
    _persist();
    NetworkTuning.update(trustAll: enabled);
    if (getIt.isRegistered<DioClient>()) {
      getIt<DioClient>().setTrustAllCerts(enabled);
    }
  }

  /// 启用 HTTP/2 (同步静态值 + 全局客户端重建适配器)
  Future<void> setEnableHttp2(bool enabled) async {
    state = state.copyWith(enableHttp2: enabled);
    _persist();
    NetworkTuning.update(http2: enabled);
    if (getIt.isRegistered<DioClient>()) {
      getIt<DioClient>().setHttp2Enabled(enabled);
    }
  }

  /// 连接重试次数 (0~5)
  Future<void> setConnectRetryCount(int count) async {
    state = state.copyWith(connectRetryCount: count.clamp(0, 5));
    _persist();
    NetworkTuning.update(retryCount: count);
  }

  /// 连接重试间隔 (ms, 100~10000)
  Future<void> setConnectRetryInterval(int ms) async {
    state = state.copyWith(connectRetryIntervalMs: ms.clamp(100, 10000));
    _persist();
    NetworkTuning.update(retryIntervalMs: ms);
  }

  // ─── 显示: 悬浮底栏 / 字体管理 / 界面缩放 / 页面过渡 ───

  /// 悬浮底栏样式
  Future<void> setFloatingBottomBar(bool enabled) async {
    state = state.copyWith(floatingBottomBar: enabled);
    _persist();
  }

  /// 界面缩放 (0.8~1.5, 系统字体缩放系数上再乘)
  Future<void> setUiScale(double scale) async {
    state = state.copyWith(uiScale: scale.clamp(0.8, 1.5));
    _persist();
  }

  /// 页面过渡动画 ('native' | 'fade' | 'slide' | 'none')
  Future<void> setPageTransition(String kind) async {
    const allowed = {'native', 'fade', 'slide', 'none'};
    if (!allowed.contains(kind)) return;
    state = state.copyWith(pageTransition: kind);
    _persist();
  }

  /// 选择全局显示字体
  ///
  /// [kind]: 'default' | 'system' | 'bundled' | 'imported'。
  /// imported 时先确保 FontLoader 已注册再切换。
  Future<void> setAppFont({required String kind, required String value}) async {
    if (kind == 'imported') {
      ImportedFont? target;
      for (final f in state.importedFonts) {
        if (f.family == value) {
          target = f;
          break;
        }
      }
      if (target == null) return;
      final ok = await FontManager.registerFamily(target.family, target.path);
      if (!ok) return; // 注册失败 (文件丢失/损坏), 保持原字体
    }
    state = state.copyWith(
      appFontKind: kind,
      appFontValue: kind == 'default' ? '' : value,
    );
    _persist();
  }

  /// 登记新导入的字体 (同 family 覆盖)
  Future<void> addImportedFont(ImportedFont font) async {
    final list = [
      ...state.importedFonts.where((f) => f.family != font.family),
      font,
    ];
    state = state.copyWith(importedFonts: list);
    _persist();
  }

  /// 移除导入字体 (删除文件; 当前正在使用时回退默认字体)
  Future<void> removeImportedFont(ImportedFont font) async {
    var kind = state.appFontKind;
    var value = state.appFontValue;
    if (kind == 'imported' && value == font.family) {
      kind = 'default';
      value = '';
    }
    await FontManager.deleteFontFile(font.path);
    state = state.copyWith(
      importedFonts:
          state.importedFonts.where((f) => f.family != font.family).toList(),
      appFontKind: kind,
      appFontValue: value,
    );
    _persist();
  }

  /// 设置主页导航栏显示的 TAB (路由路径列表, 不含固定显示的'设置')
  void setVisibleTabs(List<String> tabs) {
    state = state.copyWith(visibleTabs: List.unmodifiable(tabs));
    _persist();
  }

  void setMemberAuthBypass(bool enabled) {
    state = state.copyWith(memberAuthBypass: enabled);
    _persist();
  }

  void setWeekendClassBypass(bool enabled) {
    state = state.copyWith(weekendClassBypass: enabled);
    _persist();
  }

  void setCheckinRaceEnabled(bool enabled) {
    state = state.copyWith(checkinRaceEnabled: enabled);
    _persist();
  }

  void setShowReportInject(bool enabled) {
    state = state.copyWith(showReportInject: enabled);
    _persist();
  }

  /// 保活：保持屏幕常亮（持久化 + 应用窗口 FLAG_KEEP_SCREEN_ON）
  Future<void> setKeepScreenOn(bool enabled) async {
    state = state.copyWith(keepScreenOn: enabled);
    _persist();
    try {
      await KeepAliveChannel.setKeepScreenOn(enabled);
    } catch (_) {
      // 非 Android / 通道未实现时静默忽略
    }
  }

  /// 保活 (Windows)：提高进程优先级
  ///
  /// FFI 设置失败时状态不更新 (开关自动回弹) 并返回 false。
  Future<bool> setWindowsHighPriority(bool enabled) async {
    if (Platform.isWindows) {
      final ok = WindowsKeepAlive.setPriority(high: enabled);
      if (!ok) return false;
    }
    state = state.copyWith(windowsHighPriority: enabled);
    _persist();
    return true;
  }

  /// 保活 (Windows)：阻止系统自动休眠
  ///
  /// FFI 设置失败时状态不更新 (开关自动回弹) 并返回 false。
  Future<bool> setWindowsPreventSleep(bool enabled) async {
    if (Platform.isWindows) {
      final ok = WindowsKeepAlive.setPreventSleep(prevent: enabled);
      if (!ok) return false;
    }
    state = state.copyWith(windowsPreventSleep: enabled);
    _persist();
    return true;
  }

  // ─── KeepLiveService 保活框架 ───

  /// 当前框架配置 → 通道参数 (与 MainActivity.initFramework 键一一对应):
  /// 全部选项键扁平展开, 外加 aggressiveLevel。
  Map<String, Object> frameworkConfig() => {
    for (final entry in state.fwOptions.entries) entry.key: entry.value,
    'aggressiveLevel': state.fwAggressiveLevel,
  };

  /// 解析持久化的选项 JSON; 缺失/损坏时逐项回退默认值
  static Map<String, bool> _decodeFwOptions(String? raw) {
    final Map<String, bool> merged = {...AppSettingsState.fwOptionDefaults};
    if (raw != null) {
      try {
        final obj = jsonDecode(raw);
        if (obj is Map) {
          obj.forEach((k, v) {
            if (merged.containsKey(k) && v is bool) merged[k] = v;
          });
        }
      } catch (_) {}
    }
    return merged;
  }

  /// 解析持久化的导入字体列表 (损坏时回退空列表)
  static List<ImportedFont> _decodeImportedFonts(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final obj = jsonDecode(raw);
      if (obj is List) {
        return [
          for (final e in obj)
            if (e is Map) ImportedFont.fromJson(e as Map<String, dynamic>),
        ].where((f) => f.family.isNotEmpty && f.path.isNotEmpty).toList();
      }
    } catch (_) {}
    return const [];
  }

  /// 保活总开关: 启动/停止 KeepLiveService 框架
  Future<void> setKeepAliveEnabled(bool enabled) async {
    state = state.copyWith(keepAliveEnabled: enabled);
    _persist();
    if (!Platform.isAndroid) return;
    try {
      if (enabled) {
        await KeepAliveChannel.initFramework(frameworkConfig());
      } else {
        await KeepAliveChannel.stopFramework();
      }
    } catch (_) {}
  }

  /// 框架选项变更: 持久化后热重配框架 (stop + init) 使其立即生效
  Future<void> _reinitFrameworkIfNeeded() async {
    _persist();
    if (!Platform.isAndroid || !state.keepAliveEnabled) return;
    try {
      await KeepAliveChannel.initFramework(frameworkConfig());
    } catch (_) {}
  }

  /// 设置单个框架选项开关
  Future<void> setFwOption(String key, bool value) async {
    if (!AppSettingsState.fwOptionDefaults.containsKey(key)) return;
    state = state.copyWith(fwOptions: {...state.fwOptions, key: value});
    await _reinitFrameworkIfNeeded();
  }

  Future<void> setFwAggressiveLevel(int level) async {
    state = state.copyWith(fwAggressiveLevel: level.clamp(0, 2));
    await _reinitFrameworkIfNeeded();
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettingsState>((ref) {
      return AppSettingsNotifier();
    });

/// 最新应用版本号 (来自 assets/changelog.json 首条记录)
///
/// 不在代码中写死版本号, 升级版本时只需更新更新日志。
final latestVersionProvider = FutureProvider<String>((ref) async {
  try {
    final raw = await rootBundle.loadString('assets/changelog.json');
    final list = jsonDecode(raw) as List;
    if (list.isEmpty) return '';
    final first = list.first;
    if (first is Map) {
      return (first['version'] ?? '').toString();
    }
    return '';
  } catch (_) {
    return '';
  }
});
