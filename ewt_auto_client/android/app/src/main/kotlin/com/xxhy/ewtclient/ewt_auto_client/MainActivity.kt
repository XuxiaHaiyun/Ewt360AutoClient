package com.xxhy.ewtclient.ewt_auto_client

import android.Manifest
import android.app.ActivityManager
import android.app.AlarmManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import com.service.framework.Fw
import com.service.framework.core.AggressiveLevel
import com.service.framework.core.FwConfig
import com.service.framework.strategy.FwDeviceAdminReceiver
import com.service.framework.strategy.FwWidgetProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ewt_auto_client/pip"
    private val keepAliveChannel = "ewt_auto_client/keep_alive"
    private val notificationPermissionRequestCode = 20260829
    private val optionPermissionRequestCode = 20260830

    /**
     * 保活选项 → 所需运行时权限列表 (按系统版本取对应权限)。
     * minSdk >= 24, checkSelfPermission 无需版本守卫。
     */
    private fun permissionsForOption(key: String): List<String> = when (key) {
        "bluetoothBroadcast" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                listOf(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                emptyList()
            }
        "mediaContentObserver" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                listOf(
                    Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VIDEO,
                )
            } else {
                listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        "contactsContentObserver" -> listOf(Manifest.permission.READ_CONTACTS)
        "smsContentObserver" -> listOf(Manifest.permission.READ_SMS)
        else -> emptyList()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> {
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    }
                    "enter" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val params = PictureInPictureParams.Builder()
                                    .setAspectRatio(Rational(16, 9))
                                    .build()
                                enterPictureInPictureMode(params)
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, keepAliveChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "openSettings" -> {
                        val action = call.argument<String>("action") ?: "settings"
                        try {
                            val intent = when (action) {
                                "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                "overlay" -> Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                                "app_details" -> Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                )
                                else -> Intent(Settings.ACTION_SETTINGS)
                            }
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // ─── 电池优化豁免 ───
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            @Suppress("BatteryLife")
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(Uri.parse("package:$packageName"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // ─── 通知权限 (Android 13+) ───
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            val granted =
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                                PackageManager.PERMISSION_GRANTED
                            if (!granted) {
                                requestPermissions(
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                    notificationPermissionRequestCode
                                )
                            }
                            result.success(granted)
                        } else {
                            result.success(true)
                        }
                    }
                    // ─── KeepLiveService 强化保活框架 ───
                    "initFramework" -> {
                        runCatching {
                            initFramework(call.arguments as? Map<*, *>)
                        }.onSuccess { result.success(true) }
                            .onFailure { result.success(false) }
                    }
                    "stopFramework" -> {
                        runCatching {
                            if (Fw.isInitialized()) Fw.stop()
                        }.onSuccess { result.success(true) }
                            .onFailure { result.success(false) }
                    }
                    "isFrameworkInitialized" ->
                        result.success(runCatching { Fw.isInitialized() }.getOrDefault(false))
                    "frameworkCheck" -> {
                        runCatching {
                            if (Fw.isInitialized()) Fw.check()
                        }.onSuccess { result.success(true) }
                            .onFailure { result.success(false) }
                    }
                    // 按保活选项申请所需运行时权限 (Android 12+ 蓝牙 / 13+ 媒体 /
                    // 联系人 / 短信); 返回 true 表示调用时已全部授权
                    "requestOptionPermissions" -> {
                        val key = call.argument<String>("optionKey") ?: ""
                        val missing = permissionsForOption(key).filter {
                            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
                        }
                        if (missing.isNotEmpty()) {
                            requestPermissions(
                                missing.toTypedArray(),
                                optionPermissionRequestCode
                            )
                        }
                        result.success(missing.isEmpty())
                    }
                    // VPN 授权: 已同意返回 true; 否则拉起系统授权对话框并返回 false,
                    // 用户同意后再次调用返回 true (选项此时才可安全开启)
                    "prepareVpnAuthorization" -> {
                        val intent = VpnService.prepare(this)
                        if (intent == null) {
                            result.success(true)
                        } else {
                            runCatching { startActivity(intent) }
                            result.success(false)
                        }
                    }
                    // ─── 悬浮窗 / 精确闹钟 / 设备管理员授权 ───
                    "isOverlayGranted" ->
                        result.success(Settings.canDrawOverlays(this))
                    "openOverlaySettings" -> {
                        val ok = runCatching {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            true
                        }.getOrDefault(false)
                        result.success(ok)
                    }
                    "isExactAlarmGranted" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val am = getSystemService(ALARM_SERVICE) as AlarmManager
                            result.success(am.canScheduleExactAlarms())
                        } else {
                            result.success(true)
                        }
                    }
                    "openExactAlarmSettings" -> {
                        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            runCatching {
                                startActivity(
                                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                        .setData(Uri.parse("package:$packageName"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                true
                            }.getOrDefault(false)
                        } else {
                            false
                        }
                        if (!ok) {
                            runCatching {
                                startActivity(appDetailsIntent())
                            }
                        }
                        result.success(ok)
                    }
                    // 设备管理员: 已激活返回 true; 否则直接拉起系统激活界面并返回 false
                    "requestDeviceAdmin" -> {
                        val dpm =
                            getSystemService(DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
                        val admin = ComponentName(this, FwDeviceAdminReceiver::class.java)
                        if (dpm.isAdminActive(admin)) {
                            result.success(true)
                        } else {
                            runCatching {
                                startActivity(
                                    Intent(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                                        .putExtra(
                                            android.app.admin.DevicePolicyManager.EXTRA_DEVICE_ADMIN,
                                            admin
                                        )
                                        .putExtra(
                                            android.app.admin.DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                            "激活设备管理员后系统将持续保护本应用进程, 显著提升保活强度"
                                        )
                                )
                            }
                            result.success(false)
                        }
                    }
                    // ─── 固定应用 (屏幕固定, startLockTask 直拉系统 API) ───
                    "isAppPinned" -> {
                        val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                        result.success(
                            runCatching { am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE }
                                .getOrDefault(false)
                        )
                    }
                    // true = 已进入固定; false = 系统限制 (API<28 且未开启屏幕固定,
                    // 已代为打开相关设置页) 或调用失败, 用户完成设置后重试
                    "pinApp" -> {
                        val ok = runCatching {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ||
                                isLockToAppEnabled()
                            ) {
                                startLockTask()
                                true
                            } else {
                                openLockToAppSettings()
                                false
                            }
                        }.getOrDefault(false)
                        result.success(ok)
                    }
                    "unpinApp" -> {
                        val ok = runCatching {
                            stopLockTask()
                            true
                        }.getOrDefault(false)
                        result.success(ok)
                    }
                    // ─── 桌面卡片 (requestPinAppWidget 直拉系统 API + 模拟更新) ───
                    "isPinWidgetSupported" -> {
                        val awm = AppWidgetManager.getInstance(this)
                        result.success(
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                                awm != null &&
                                awm.isRequestPinAppWidgetSupported
                        )
                    }
                    "isWidgetBound" -> result.success(WidgetUpdateScheduler.isWidgetBound(this))
                    // 拉起系统"添加卡片到桌面"确认; 用户确认后由
                    // KeepAliveWidgetPinReceiver 启动模拟更新闹钟
                    "pinKeepAliveWidget" -> {
                        val awm = AppWidgetManager.getInstance(this)
                        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            awm != null && awm.isRequestPinAppWidgetSupported
                        ) {
                            runCatching {
                                val callback = PendingIntent.getBroadcast(
                                    this,
                                    0,
                                    Intent(this, KeepAliveWidgetPinReceiver::class.java),
                                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                                )
                                awm.requestPinAppWidget(
                                    ComponentName(this, FwWidgetProvider::class.java),
                                    null,
                                    callback
                                )
                            }.getOrDefault(false)
                        } else {
                            false
                        }
                        result.success(ok)
                    }
                    // 手动触发一次卡片模拟更新 (刷新内容并拉起前台服务)
                    "refreshKeepAliveWidget" -> {
                        val ok = runCatching {
                            if (WidgetUpdateScheduler.isWidgetBound(this)) {
                                sendBroadcast(WidgetUpdateScheduler.updateIntent(this))
                                true
                            } else {
                                false
                            }
                        }.getOrDefault(false)
                        result.success(ok)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 用户是否已在系统设置中开启"屏幕固定" (API<28 时 startLockTask 的前置条件) */
    private fun isLockToAppEnabled(): Boolean = runCatching {
        Settings.Secure.getInt(
            contentResolver, "lock_to_app_enabled", 0
        ) == 1
    }.getOrDefault(false)

    /** 打开系统"屏幕固定"设置页 (优先专页, 失败回退安全设置, 再回退应用详情) */
    private fun openLockToAppSettings(): Boolean {
        val ok = runCatching {
            startActivity(
                Intent("android.settings.LOCK_TO_APP_SETTINGS")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }.getOrDefault(false)
        if (ok) return true
        return runCatching {
            startActivity(
                Intent(Settings.ACTION_SECURITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }.getOrDefault(false).also { if (!it) runCatching { startActivity(appDetailsIntent()) } }
    }

    private fun appDetailsIntent(): Intent = Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.parse("package:$packageName")
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /**
     * 初始化/重配 KeepLiveService 框架 (Fw.init)。
     *
     * [config] 为 Dart 侧 frameworkConfig() 的扁平映射: 选项键 → bool
     * (键集见 FwConfigExt.FwOptionKeys), 外加 aggressiveLevel (0/1/2)。
     * 已初始化时先 stop 再 init, 保证配置变更立即生效。
     */
    private fun initFramework(config: Map<*, *>?) {
        val aggressive = (config?.get("aggressiveLevel") as? Number)?.toInt() ?: 1

        if (Fw.isInitialized()) Fw.stop()
        Fw.init(application) {
            enableForegroundService = true
            resetFwOptions()
            for ((k, v) in config ?: emptyMap<Any, Any>()) {
                val key = k as? String ?: continue
                if (key == "aggressiveLevel") continue
                // 授权门控: VPN/伴侣设备/设备管理员未完成系统授权时强制关闭
                val want = v is Boolean && v
                if (want && sanitizeConsentGatedOption(application, key, true)) {
                    applyFwOption(key, true)
                }
            }
            aggressiveLevel = when (aggressive) {
                0 -> AggressiveLevel.LOW
                2 -> AggressiveLevel.HIGH
                else -> AggressiveLevel.MEDIUM
            }
            notificationTitle = "保活运行中"
            notificationContent = "应用正在后台保持运行"
            enableDebugLog = false
        }
    }
}
