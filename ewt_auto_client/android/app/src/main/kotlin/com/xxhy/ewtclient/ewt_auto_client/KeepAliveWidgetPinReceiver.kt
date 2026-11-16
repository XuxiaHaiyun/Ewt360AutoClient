package com.xxhy.ewtclient.ewt_auto_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 桌面卡片"固定到桌面"成功回调接收器。
 *
 * requestPinAppWidget 的用户确认成功后, 系统会发送此处登记的 PendingIntent;
 * 收到即对齐卡片模拟更新闹钟 (启动模拟更新, 保持后台驻留)。
 */
class KeepAliveWidgetPinReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        WidgetUpdateScheduler.sync(context)
    }
}
