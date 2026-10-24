package com.daoban.shiftassistantpro

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 值班时段自动勿扰：到点把系统勿扰切到排定的状态。
 *
 * 勿扰策略授权（`isNotificationPolicyAccessGranted`）没给的时候**什么都不做** ——
 * 切不动就是切不动，静默不崩；用户在「我的」页的开关卡上会被引导去授权。
 *
 * 不响铃、不弹通知：这是一次系统状态的切换，不是一条提醒。与响铃 / 提醒链路
 * 共用 [AlarmScheduler] 的精确闹钟机制，但没有续排（每个时刻都是一次性的，
 * 每次重排全量重建）。
 */
class DndReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra("id", -1)
        val dndOn = intent.getBooleanExtra("dndOn", false)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!nm.isNotificationPolicyAccessGranted) {
            AlarmLog.info(context, "DndReceiver: 无勿扰策略授权，跳过 (id=$id, dndOn=$dndOn)")
            return
        }
        val filter = if (dndOn) {
            NotificationManager.INTERRUPTION_FILTER_PRIORITY
        } else {
            NotificationManager.INTERRUPTION_FILTER_ALL
        }
        try {
            nm.setInterruptionFilter(filter)
            AlarmLog.info(context, "DndReceiver: 勿扰切换完成 (id=$id, filter=$filter)")
        } catch (e: Exception) {
            AlarmLog.error(context, "DndReceiver: 切换失败: ${e.message}")
        }
    }
}
