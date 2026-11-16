package com.xxhy.ewtclient.ewt_auto_client

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.service.framework.Fw
import com.service.framework.core.AggressiveLevel
import org.json.JSONObject

/**
 * 自定义 Application: 进程冷启动 (含被系统回收后重建) 时,
 * 直接读取 Flutter SharedPreferences 中已持久化的保活设置,
 * 在任何 Activity/Flutter 引擎启动前恢复 KeepLiveService 框架保活。
 *
 * 注意: Fw.init 必须无条件执行 (禁用态 = 全策略显式关闭), 不能只在保活开启时
 * 才初始化 —— 框架 AAR 的 Manifest 会自动合并若干系统可随时绑定的组件
 * (如 MediaRouteProviderService), 其 onCreate 内部日志会读取 Fw 的 lateinit
 * config; 若 Fw 未初始化, 系统一绑定即抛 UninitializedPropertyAccessException。
 *
 * 读取的是 shared_preferences 插件的存储格式: 文件名 FlutterSharedPreferences,
 * key 前缀 "flutter." (与 Dart 侧 settings_provider 的 _prefix 拼接结果一致)。
 */
class EwtApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        try {
            val prefs = getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            applyFramework(prefs, prefs.getBoolean(PREF_ENABLED, false))
            // 桌面卡片模拟更新闹钟: 按当前绑定状态对齐
            // (进程被杀重建后闹钟丢失, 重建恢复; 卡片被移除则自动取消)
            WidgetUpdateScheduler.sync(this)
        } catch (e: Exception) {
            // 框架初始化失败不应阻塞应用启动
            Log.w(TAG, "init keep-alive framework failed", e)
        }
    }

    /**
     * 初始化 Fw 框架。
     *
     * [enabled] 为 true 时按持久化选项启用各策略; 为 false 时全策略显式关闭
     * (仅初始化 config, 让框架组件在被系统绑定时可安全读取配置, 不产生任何行为)。
     */
    private fun applyFramework(prefs: SharedPreferences, enabled: Boolean) {
        Fw.init(this) {
            enableForegroundService = enabled
            resetFwOptions()
            if (enabled) {
                runCatching {
                    // 选项以 JSON 对象持久化 (与 Dart 侧 frameworkConfig 键一致)
                    val json = prefs.getString(PREF_OPTIONS, null) ?: return@runCatching
                    val obj = JSONObject(json)
                    for (key in FwOptionKeys) {
                        // 授权门控: VPN/伴侣设备/设备管理员未授权时保持关闭,
                        // 避免服务启动后无法 startForeground 导致宿主崩溃
                        val want = obj.optBoolean(key, false)
                        if (want &&
                            sanitizeConsentGatedOption(
                                this@EwtApplication,
                                key,
                                true,
                            )
                        ) {
                            applyFwOption(key, true)
                        }
                    }
                }
                aggressiveLevel = when (prefs.getInt(PREF_AGGRESSIVE, 1)) {
                    0 -> AggressiveLevel.LOW
                    2 -> AggressiveLevel.HIGH
                    else -> AggressiveLevel.MEDIUM
                }
            }
            notificationTitle = "保活运行中"
            notificationContent = "应用正在后台保持运行"
            enableDebugLog = false
        }
    }

    companion object {
        private const val TAG = "EwtApplication"

        // 与 Dart 侧 settings_provider 的键保持一致 (shared_preferences 自动加 "flutter." 前缀)
        const val PREF_ENABLED = "flutter.settings_keepAliveEnabled"
        const val PREF_OPTIONS = "flutter.settings_fwOptions"
        const val PREF_AGGRESSIVE = "flutter.settings_fwAggressiveLevel"
    }
}
