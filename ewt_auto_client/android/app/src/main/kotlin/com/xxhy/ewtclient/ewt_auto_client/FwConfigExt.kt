package com.xxhy.ewtclient.ewt_auto_client

import android.app.admin.DevicePolicyManager
import android.companion.CompanionDeviceManager
import android.app.AlarmManager
import android.content.Context
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import com.service.framework.core.FwConfig

/**
 * Dart 侧保活选项键 → FwConfig.Builder 开关的统一映射。
 *
 * 键名与 Dart 侧 settings_provider 的 fwOptions / 通道 config 一一对应。
 * MediaRoute 三项 (provider/provider2/mediaIntentActivity) 不在此列:
 * 其服务已从合并 Manifest 移除, 不支持开启。
 */
val FwOptionKeys = listOf(
    "mediaSession",
    "scheduledWakeup",
    "accountSync",
    "systemBroadcast",
    "bluetoothBroadcast",
    "silentAudio",
    "mediaButtonReceiver",
    "usbBroadcast",
    "nfcBroadcast",
    "mediaMountBroadcast",
    "mediaContentObserver",
    "contactsContentObserver",
    "smsContentObserver",
    "settingsContentObserver",
    "fileObserver",
    "dualProcess",
    "nativeDaemon",
    "nativeSocket",
    "forceStopResistance",
    "onePixel",
    "lockScreenActivity",
    "floatWindow",
    "dreamService",
    "tileService",
    "widget",
    "deviceAdmin",
    "vpnService",
    "companionDevice",
    "callStyleNotification",
    "mediaSessionNotification",
)

/** 将单个选项应用到 Builder (未知键忽略, 保证前后端版本错位时安全) */
fun FwConfig.Builder.applyFwOption(key: String, value: Boolean) {
    when (key) {
        "mediaSession" -> enableMediaSession = value
        "scheduledWakeup" -> {
            // 定时唤醒三件套作为一个开关
            enableJobScheduler = value
            enableWorkManager = value
            enableAlarmManager = value
        }
        "accountSync" -> enableAccountSync = value
        "systemBroadcast" -> enableSystemBroadcast = value
        "bluetoothBroadcast" -> enableBluetoothBroadcast = value
        "silentAudio" -> enableSilentAudio = value
        "mediaButtonReceiver" -> enableMediaButtonReceiver = value
        "usbBroadcast" -> enableUsbBroadcast = value
        "nfcBroadcast" -> enableNfcBroadcast = value
        "mediaMountBroadcast" -> enableMediaMountBroadcast = value
        "mediaContentObserver" -> enableMediaContentObserver = value
        "contactsContentObserver" -> enableContactsContentObserver = value
        "smsContentObserver" -> enableSmsContentObserver = value
        "settingsContentObserver" -> enableSettingsContentObserver = value
        "fileObserver" -> enableFileObserver = value
        "dualProcess" -> enableDualProcess = value
        "nativeDaemon" -> enableNativeDaemon = value
        "nativeSocket" -> enableNativeSocket = value
        "forceStopResistance" -> enableForceStopResistance = value
        "onePixel" -> enableOnePixelActivity = value
        "lockScreenActivity" -> enableLockScreenActivity = value
        "floatWindow" -> enableFloatWindow = value
        "dreamService" -> enableDreamService = value
        "tileService" -> enableTileService = value
        "widget" -> enableWidget = value
        "deviceAdmin" -> enableDeviceAdmin = value
        "vpnService" -> enableVpnService = value
        "companionDevice" -> enableCompanionDevice = value
        "callStyleNotification" -> enableCallStyleNotification = value
        "mediaSessionNotification" -> enableMediaSessionNotification = value
    }
}

/** 全部选项归零 (禁用态零行为的基线, 随后按配置逐项开启) */
fun FwConfig.Builder.resetFwOptions() {
    FwOptionKeys.forEach { applyFwOption(it, false) }
}

/**
 * 需用户主动授权的策略门控: 授权未完成时强制关闭。
 *
 * 这些策略内部会 startForegroundService 拉起服务; 若因缺少授权在
 * onStartCommand 里提前失败而未调用 startForeground (实测 FwVpnService:
 * 未完成系统 VPN 授权时 establish() 返回 null), 系统会在超时后抛
 * ForegroundServiceDidNotStartInTimeException 导致宿主崩溃。
 *
 * 返回该选项最终是否可以开启。
 */
fun sanitizeConsentGatedOption(context: Context, key: String, want: Boolean): Boolean {
    if (!want) return false
    return when (key) {
        // VPN: prepare() 返回 null 即用户已授予同意
        "vpnService" -> VpnService.prepare(context) == null
        // 伴侣设备: 已存在本应用的设备关联记录
        "companionDevice" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val cdm =
                    context.getSystemService(CompanionDeviceManager::class.java)
                cdm?.associations?.isNotEmpty() == true
            } else {
                false
            }
        // 设备管理员: 本应用已被激活为活动管理员
        "deviceAdmin" -> {
            val dpm = context.getSystemService(DevicePolicyManager::class.java)
            dpm?.activeAdmins?.any {
                it.packageName == context.packageName &&
                    it.className.contains("DeviceAdmin")
            } == true
        }
        // 悬浮窗: 未授予"显示在其他应用上层"权限时浮窗添加视图会抛异常
        "floatWindow" -> Settings.canDrawOverlays(context)
        // 精确闹钟: Android 12+ 未授权时 setExact 抛 SecurityException
        "scheduledWakeup" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                am.canScheduleExactAlarms()
            } else {
                true
            }
        else -> true
    }
}
