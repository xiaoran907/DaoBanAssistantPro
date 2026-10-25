package com.daoban.shiftassistantpro

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteException
import android.provider.CalendarContract

/**
 * 日历同步：**ContentResolver 直写 CalendarContract**（本地日历账户），
 * 不依赖第三方插件 —— vivo 等国产 ROM 上 `device_calendar_plus` 的
 * createEvent 往往静默失败（写的账户日历不被系统日历 App 渲染）。
 *
 * 日历定位三级策略（用户 2026-10-25 提供方案）：
 * 1. 已存在 id 直接复用；
 * 2. 匹配本地日历账户（`ACCOUNT_TYPE_LOCAL`）；
 * 3. 回退 `ACCOUNT_TYPE_LOCAL` 下创建一个「倒班助手」日历。
 *
 * 事件写进 `CalendarContract.Events`，带 `CUSTOM_APP_PACKAGE` 用于按包名归属，
 * 后续 `purgeEventsNotIn` 清本应用漏记 eventId 的残留。
 *
 * 所有失败点 `runCatching` 吞掉、只写 Log，不向 Dart 抛异常 —— 日历同步是
 * 锦上添花，失败不该让 App 崩。
 */
object CalendarSyncManager {

    const val APP_CALENDAR_NAME = "倒班助手"

    /** 事件归属包名（Android 日历 API 的自定义字段）。 */
    const val CUSTOM_APP_PACKAGE = "com.daoban.shiftassistantpro"

    private const val TAG = "CalendarSyncManager"

    /** 本地日历账户：Android 内置、无需 Google 账户，vivo 等国产 ROM 都支持。 */
    private const val ACCOUNT_TYPE_LOCAL = CalendarContract.ACCOUNT_TYPE_LOCAL

    /** 是否已授予写日历权限（按系统授予态判断，可靠）。 */
    fun hasCalendarWrite(context: Context): Boolean =
        context.checkSelfPermission(android.Manifest.permission.WRITE_CALENDAR) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /** 定位可写日历：优先已存 id，其次本地账户日历，回退创建「倒班助手」。 */
    fun findOrCreateCalendar(context: Context, savedId: String?): String? {
        val resolver = context.contentResolver
        if (!savedId.isNullOrEmpty() && calendarExists(resolver, savedId)) return savedId

        // 2. 本地账户日历 —— 匹配任一可见的本地日历。
        queryCalendars(resolver, listOf("_id", "account_name", "calendar_displayName"))
            .firstOrNull { it["account_name"] == ACCOUNT_TYPE_LOCAL }
            ?.let { return nullSafeId(it["_id"]) }

        // 3. 建一个「倒班助手」日历（本地账户）。
        return runCatching {
            val values = ContentValues().apply {
                put(CalendarContract.Calendars.ACCOUNT_NAME, ACCOUNT_TYPE_LOCAL)
                put(CalendarContract.Calendars.ACCOUNT_TYPE, ACCOUNT_TYPE_LOCAL)
                put(CalendarContract.Calendars.NAME, APP_CALENDAR_NAME)
                put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, APP_CALENDAR_NAME)
                put(CalendarContract.Calendars.CALENDAR_COLOR, 0xFF1925AC.toInt())
                put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
                put(CalendarContract.Calendars.VISIBLE, 1)
                put(CalendarContract.Calendars.SYNC_EVENTS, 1)
            }
            val uri = resolver.insert(
                CalendarContract.Calendars.CONTENT_URI.buildUpon()
                    .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, ACCOUNT_TYPE_LOCAL)
                    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, ACCOUNT_TYPE_LOCAL)
                    .build(),
                values,
            )
            nullSafeId(uri?.lastPathSegment ?: "")
        }.getOrNull()
            ?: queryCalendars(resolver, listOf("_id", "account_name", "calendar_displayName"))
            .firstOrNull()
            ?.let { nullSafeId(it["_id"]) } // 创建失败回退首个可见日历（只读也能读）
    }

    private fun queryCalendars(
        resolver: android.content.ContentResolver,
        projection: List<String>,
    ): List<Map<String, Any?>> = runCatching {
        resolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection.toTypedArray(), null, null,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME + " ASC",
        )?.use { c ->
            val out = ArrayList<Map<String, Any?>>()
            while (c.moveToNext()) {
                val m = HashMap<String, Any?>()
                for (col in projection) {
                    val i = c.getColumnIndex(col)
                    if (i >= 0) m[col] = c.getString(i)
                }
                out.add(m)
            }
            out
        } ?: emptyList()
    }.getOrDefault(emptyList())

    private fun calendarExists(resolver: android.content.ContentResolver, id: String): Boolean =
        runCatching {
            resolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                arrayOf("_id"), "_id = ?", arrayOf(id), null,
            )?.use { it.count > 0 } ?: false
        }.getOrDefault(false)

    private fun nullSafeId(v: Any?): String? = v?.toString()?.takeIf { it.isNotEmpty() }

    /**
     * 写入一条班次事件，返回新事件的 eventId（Dart 侧存映射做增量）。
     * [remindMin] > 0 时同时插 Reminder（METHOD=0 系统通知）。失败返回 null。
     */
    fun insertEvent(
        context: Context,
        calendarId: String,
        title: String,
        description: String?,
        startMs: Long,
        endMs: Long,
        remindMin: Int,
        appKey: String,
    ): String? {
        val resolver = context.contentResolver
        return runCatching {
            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calendarId)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, description)
                put(CalendarContract.Events.DTSTART, startMs)
                put(CalendarContract.Events.DTEND, endMs)
                put(CalendarContract.Events.EVENT_TIMEZONE, java.util.TimeZone.getDefault().id)
                put(CalendarContract.Events.HAS_ALARM, if (remindMin > 0) 1 else 0)
                put(CalendarContract.Events.CUSTOM_APP_PACKAGE, appKey)
            }
            val uri = resolver.insert(CalendarContract.Events.CONTENT_URI, values) ?: return@runCatching null
            val eventId = uri.lastPathSegment ?: return@runCatching null
            if (remindMin > 0) runCatching {
                val rv = ContentValues().apply {
                    put(CalendarContract.Reminders.EVENT_ID, eventId.toLong())
                    put(CalendarContract.Reminders.MINUTES, remindMin)
                    put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                }
                resolver.insert(CalendarContract.Reminders.CONTENT_URI, rv)
            }
            eventId
        }.getOrNull()
    }

    /** 更新事件（标题/描述/时间/提醒）。失败静默。 */
    fun updateEvent(
        context: Context,
        eventId: String,
        title: String,
        description: String?,
        startMs: Long,
        endMs: Long,
        remindMin: Int,
    ) {
        val resolver = context.contentResolver
        runCatching {
            val values = ContentValues().apply {
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, description)
                put(CalendarContract.Events.DTSTART, startMs)
                put(CalendarContract.Events.DTEND, endMs)
                put(CalendarContract.Events.HAS_ALARM, if (remindMin > 0) 1 else 0)
            }
            resolver.update(CalendarContract.Events.CONTENT_URI, values, "_id = ?", arrayOf(eventId))
            if (remindMin > 0) {
                resolver.delete(
                    CalendarContract.Reminders.CONTENT_URI,
                    CalendarContract.Reminders.EVENT_ID + " = ?",
                    arrayOf(eventId),
                )
                val rv = ContentValues().apply {
                    put(CalendarContract.Reminders.EVENT_ID, eventId.toLong())
                    put(CalendarContract.Reminders.MINUTES, remindMin)
                    put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                }
                resolver.insert(CalendarContract.Reminders.CONTENT_URI, rv)
            }
        }
    }

    /** 删单条事件。 */
    fun deleteEvent(context: Context, eventId: String) {
        val resolver = context.contentResolver
        runCatching {
            resolver.delete(
                CalendarContract.Events.CONTENT_URI, "_id = ?", arrayOf(eventId),
            )
        }
    }

    /** 批量删（`_id IN (...)`）。返回尝试删除条数，负数标 warning。 */
    fun deleteEventsByIds(context: Context, eventIds: List<String>): Int {
        if (eventIds.isEmpty()) return 0
        val resolver = context.contentResolver
        return runCatching {
            val placeholders = eventIds.joinToString(",") { "?" }
            resolver.delete(
                CalendarContract.Events.CONTENT_URI,
                "_id IN ($placeholders)", eventIds.toTypedArray(),
            )
        }.onFailure {
            AlarmLog.error(context, "CalendarSyncManager: 批量删除失败: ${it.message}")
        }.getOrDefault(-1)
    }

    /** 按包名删本应用全部事件（清早期漏记 eventId 的残留）。 */
    fun deleteAllEvents(context: Context): Int {
        val resolver = context.contentResolver
        return runCatching {
            resolver.delete(
                CalendarContract.Events.CONTENT_URI,
                "${CalendarContract.Events.CUSTOM_APP_PACKAGE} = ?",
                arrayOf(CUSTOM_APP_PACKAGE),
            )
        }.onFailure {
            AlarmLog.error(context, "CalendarSyncManager: 清空本应用事件失败: ${it.message}")
        }.getOrDefault(-1)
    }

    /**
     * 保留 [keepEventIds]，删掉本应用其余事件（按包名查全部再减 keepIds）。
     * 用于清早期版本漏记 eventId 的残留。
     */
    fun purgeEventsNotIn(context: Context, keepEventIds: Set<String>) {
        val resolver = context.contentResolver
        val mine = runCatching {
            resolver.query(
                CalendarContract.Events.CONTENT_URI,
                arrayOf("_id"),
                "${CalendarContract.Events.CUSTOM_APP_PACKAGE} = ?",
                arrayOf(CUSTOM_APP_PACKAGE), null,
            )?.use { c ->
                val ids = ArrayList<String>()
                while (c.moveToNext()) ids.add(c.getString(0))
                ids
            } ?: emptyList()
        }.getOrDefault(emptyList())
        val toDelete = mine.filterNot { it in keepEventIds }
        if (toDelete.isNotEmpty()) {
            deleteEventsByIds(context, toDelete)
        }
    }
}