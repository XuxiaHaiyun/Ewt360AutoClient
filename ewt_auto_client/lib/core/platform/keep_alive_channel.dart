/// 保活能力 MethodChannel 封装: Android 端对接 KeepLiveService 框架,
/// 提供屏幕常亮、权限申请、屏幕固定、桌面卡片与框架初始化/巡检等通道;
/// 非 Android 平台全部静默 no-op 返回。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 保活能力平台通道
///
/// Android 端保活统一由 KeepLiveService 框架 (keeplive-framework) 承担,
/// [MainActivity] 提供初始化/停止/巡检通道; Windows 端由 [WindowsKeepAlive]
/// (dart:ffi) 实现, 其余平台调用会抛出 [PlatformException] (notImplemented)，
/// 调用方应 try/catch 静默忽略。
class KeepAliveChannel {
  KeepAliveChannel._();

  static const MethodChannel _channel = MethodChannel(
    'ewt_auto_client/keep_alive',
  );

  /// 保持屏幕常亮 (Android: WindowManager.FLAG_KEEP_SCREEN_ON)
  static Future<void> setKeepScreenOn(bool on) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setKeepScreenOn', {'on': on});
  }

  /// 跳转到系统设置页
  ///
  /// [action] 取值: 'battery' | 'overlay' | 'app_details' | 'settings'
  /// 返回是否成功拉起。
  static Future<bool> openAndroidSettings(String action) async {
    if (!Platform.isAndroid) return false;
    final result = await _channel.invokeMethod<bool>('openSettings', {
      'action': action,
    });
    return result == true;
  }

  /// 是否已豁免电池优化 (厂商 ROM 可能仍查杀, 豁免显著降低概率)
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>(
      'isIgnoringBatteryOptimizations',
    );
    return r == true;
  }

  /// 直接弹出系统"忽略电池优化"授权对话框 (取消时回退 openAndroidSettings('battery'))
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>(
      'requestIgnoreBatteryOptimizations',
    );
    return r == true;
  }

  /// 请求通知权限 (Android 13+), 返回当前是否已授权
  static Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>(
      'requestNotificationPermission',
    );
    return r == true;
  }

  /// 按保活选项申请所需运行时权限 (蓝牙/媒体/联系人/短信等, 键同框架选项)。
  ///
  /// 返回 true 表示调用时已全部授权; false 表示弹出了系统授权对话框,
  /// 用户决定在对话框回调中异步生效 (调用方应提示授权后策略才完整生效)。
  static Future<bool> requestOptionPermissions(String optionKey) async {
    if (!Platform.isAndroid) return true;
    final r = await _channel.invokeMethod<bool>('requestOptionPermissions', {
      'optionKey': optionKey,
    });
    return r == true;
  }

  /// VPN 授权检查。
  ///
  /// 已同意过系统 VPN 对话框返回 true; 否则拉起授权对话框并返回 false,
  /// 用户同意后再次调用返回 true (vpnService 选项此时才可安全开启)。
  static Future<bool> prepareVpnAuthorization() async {
    if (!Platform.isAndroid) return true;
    final r = await _channel.invokeMethod<bool>('prepareVpnAuthorization');
    return r == true;
  }

  // ─── 悬浮窗 / 精确闹钟 / 设备管理员授权 ───

  /// 是否已授予"显示在其他应用上层"权限 (floatWindow 选项前置条件)
  static Future<bool> isOverlayGranted() async {
    if (!Platform.isAndroid) return true;
    final r = await _channel.invokeMethod<bool>('isOverlayGranted');
    return r == true;
  }

  /// 直接打开系统"显示在其他应用上层"授权页
  static Future<void> openOverlaySettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openOverlaySettings');
  }

  /// 是否已授予精确闹钟权限 (Android 12+; scheduledWakeup 选项前置条件)
  static Future<bool> isExactAlarmGranted() async {
    if (!Platform.isAndroid) return true;
    final r = await _channel.invokeMethod<bool>('isExactAlarmGranted');
    return r == true;
  }

  /// 直接打开系统"闹钟和提醒"授权页 (Android 12+; 低版本为 no-op)
  static Future<void> openExactAlarmSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openExactAlarmSettings');
  }

  /// 设备管理员激活检查。
  ///
  /// 已激活返回 true; 否则直接拉起系统激活界面并返回 false,
  /// 用户激活后再次调用返回 true (deviceAdmin 选项此时才可安全开启)。
  static Future<bool> requestDeviceAdmin() async {
    if (!Platform.isAndroid) return true;
    final r = await _channel.invokeMethod<bool>('requestDeviceAdmin');
    return r == true;
  }

  // ─── 固定应用 (屏幕固定) ───

  /// 当前是否处于固定 (锁屏任务) 状态
  static Future<bool> isAppPinned() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('isAppPinned');
    return r == true;
  }

  /// 直接固定本应用 (Activity.startLockTask)。
  ///
  /// Android 9+ 系统直接弹出固定确认对话框; 8.x 及以下需先在系统设置开启
  /// "屏幕固定" (未开启时原生侧会代为打开设置页) 并返回 false,
  /// 用户开启后重试即可。
  static Future<bool> pinApp() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('pinApp');
    return r == true;
  }

  /// 解除固定 (Activity.stopLockTask)
  static Future<bool> unpinApp() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('unpinApp');
    return r == true;
  }

  // ─── 桌面卡片 (AppWidget) ───

  /// 当前桌面是否支持直接拉起"添加卡片"确认 (API 26+ 且启动器支持)
  static Future<bool> isPinWidgetSupported() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('isPinWidgetSupported');
    return r == true;
  }

  /// 桌面上是否已添加本应用卡片
  static Future<bool> isWidgetBound() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('isWidgetBound');
    return r == true;
  }

  /// 直接拉起系统"添加卡片到桌面"确认 (requestPinAppWidget)。
  ///
  /// 用户确认后原生侧自动启动"模拟更新"闹钟 (每 5 分钟刷新卡片并拉起
  /// 前台服务保持后台驻留); 返回 false 表示系统不支持或拉起失败。
  static Future<bool> pinKeepAliveWidget() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('pinKeepAliveWidget');
    return r == true;
  }

  /// 手动触发一次卡片模拟更新 (刷新内容并拉起前台服务)
  static Future<bool> refreshKeepAliveWidget() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('refreshKeepAliveWidget');
    return r == true;
  }

  // ─── KeepLiveService 保活框架 (Fw) ───

  /// 初始化/重配保活框架。
  ///
  /// [config] 键: mediaSession / bluetoothBroadcast / accountSync /
  /// scheduledWakeup / silentAudio / onePixel (bool), aggressiveLevel (0/1/2)。
  /// 已初始化时先 stop 再 init, 保证配置变更生效。
  static Future<bool> initFramework(Map<String, Object> config) async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('initFramework', config);
    return r == true;
  }

  /// 停止保活框架的全部策略
  static Future<bool> stopFramework() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('stopFramework');
    return r == true;
  }

  /// 框架是否已初始化
  static Future<bool> isFrameworkInitialized() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('isFrameworkInitialized');
    return r == true;
  }

  /// 手动巡检: 检查各策略存活并自动补偿
  static Future<bool> frameworkCheck() async {
    if (!Platform.isAndroid) return false;
    final r = await _channel.invokeMethod<bool>('frameworkCheck');
    return r == true;
  }
}
