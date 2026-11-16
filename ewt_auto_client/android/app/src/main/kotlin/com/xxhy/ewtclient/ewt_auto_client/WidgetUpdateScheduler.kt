package com.xxhy.ewtclient.ewt_auto_client

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import com.service.framework.strategy.FwWidgetProvider

/**
 * 桌面卡片"模拟更新"调度器。
 *
 * 卡片由 keeplive-framework 的 [FwWidgetProvider] 承载, 其 onUpdate 会
 * 渲染卡片视图并拉起前台服务 (保活拉起入口)。本调度器用 AlarmManager
 * 周期 (5 分钟) 向其发送 APPWIDGET_UPDATE, 实现:
 *   1. 卡片内容刷新 (模拟更新);
 *   2. 进程被周期唤醒 + 前台服务续命 → 后台驻留。
 *
 * 卡片绑定状态变化 (通过设置页添加 / 用户从桌面移除) 由 [sync] 统一处理:
 * 有绑定卡片则武装闹钟, 无绑定卡片则取消, 避免无卡片时空跑闹钟。
 */
object WidgetUpdateScheduler {
    private const val REQUEST_CODE = 20260926

    /** 模拟更新周期: 5 分钟 (框架自身系统级 updatePeriodMillis 为 30 分钟, 此为增强) */
    private const val INTERVAL_MS = 5 * 60 * 1000L

    private fun widgetComponent(context: Context): ComponentName =
        ComponentName(context, FwWidgetProvider::class.java)

    /** 桌面上是否还有本应用卡片 */
    fun isWidgetBound(context: Context): Boolean = runCatching {
        val awm = AppWidgetManager.getInstance(context)
        if (awm == null) {
            false
        } else {
            awm.getAppWidgetIds(widgetComponent(context)).isNotEmpty()
        }
    }.getOrDefault(false)

    /** 触发一次卡片更新的广播 (卡片 onUpdate 内会拉起前台服务) */
    fun updateIntent(context: Context): Intent =
        Intent(context, FwWidgetProvider::class.java)
            .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)

    /** 武装周期模拟更新闹钟, 并立即刷新一次卡片 */
    fun arm(context: Context) {
        runCatching {
            val am =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                updateIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            am.setInexactRepeating(
                AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + INTERVAL_MS,
                INTERVAL_MS,
                pi,
            )
            context.sendBroadcast(updateIntent(context))
        }
    }

    /** 取消周期模拟更新闹钟 */
    fun cancel(context: Context) {
        runCatching {
            val am =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                updateIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            am.cancel(pi)
        }
    }

    /** 按当前卡片绑定状态对齐闹钟 (添加卡片后 / 用户移除卡片后 / 进程启动时调用) */
    fun sync(context: Context) {
        if (isWidgetBound(context)) {
            arm(context)
        } else {
            cancel(context)
        }
    }
}
