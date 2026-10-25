import 'dart:convert';

import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/app_repository.dart';
import '../../domain/schedule_chain.dart';
import '../../domain/shift_rotation.dart';

/// 日历同步服务：单向推送排班到系统日历（D19~D24）。
///
/// 幂等映射存在数据库 `calendar_event_mapping_rows`（键
/// `scheduleId:day:classId:seg`），增量更新不产生大量「删建」痕迹：无映射 →
/// createEvent；有映射且指纹变了 → updateEvent；窗口外 → deleteEvent。
class CalendarSyncService {
  CalendarSyncService(this._repo);

  final AppRepository _repo;

  static const String _prefsKeyCalendarId = 'calendarSyncCalendarId';
  static const String _prefsKeyEnabled = 'calendarSyncEnabled';
  static const String _prefsKeyLegacyMap = 'calendarSyncEventMap';
  static const int syncDaysAhead = 60;

  /// 生成未来 [days] 天的班次实例列表：**每个时段一条**（多时段班次的每段独立，
  /// 「这套方案是否出现在多段时间线上」也按天解析，与日历同源）。
  ///
  /// 顶层纯函数：不碰仓库、不读时钟（[from] 传入），可单测 key 格式与跨午夜推算。
  static List<SyncEvent> syncEventsFor(
    ScheduleChain chain,
    DateTime from,
    int days,
  ) {
    final events = <SyncEvent>[];
    for (var i = 0; i < days; i++) {
      final date = DateTime(from.year, from.month, from.day + i);
      final dayNum = dayNumber(date);

      final schedule = chain.scheduleOn(date);
      if (schedule == null) continue;

      final scheduleId = chain.scheduleIdOn(date) ?? 0;
      for (final shift in schedule.shiftOn(date)) {
        if (shift.isRest) continue;
        final classId = shift.id;
        if (classId == null) continue;
        final segs = shift.allSegments;
        for (var s = 0; s < segs.length; s++) {
          final seg = segs[s];
          // 端点允许 ≥ 1440（跨过午夜后继续累加），结束还有「end < start」的
          // 回绕表示（22:00–06:00 存成 1320→360）—— 两种都要换算到正确的
          // 那一天。DateTime(y, m, d + n) 重建再 add 的理由见 shiftAlarmFireAt。
          final startDay = seg.startMinute ~/ 1440;
          final startClock = seg.startMinute % 1440;
          final e = seg.endMinute;
          final int endDay;
          final int endClock;
          if (e >= 1440) {
            endDay = e ~/ 1440;
            endClock = e % 1440;
          } else if (e < seg.startMinute) {
            endDay = 1;
            endClock = e;
          } else {
            endDay = 0;
            endClock = e;
          }
          final startTime = DateTime(date.year, date.month, date.day + startDay,
              startClock ~/ 60, startClock % 60);
          final endTime = DateTime(date.year, date.month, date.day + endDay,
              endClock ~/ 60, endClock % 60);
          final desc = buildSegmentDescription(seg);
          final key = '$scheduleId:$dayNum:$classId:$s';
          events.add(SyncEvent(
            key: key,
            title: shift.name,
            startDate: startTime,
            endDate: endTime,
            description: desc,
            fingerprint: '$key|${shift.name}|'
                '${startTime.millisecondsSinceEpoch}|'
                '${endTime.millisecondsSinceEpoch}|$desc',
          ));
        }
      }
    }
    return events;
  }

  /// 同步到系统日历：创建 / 更新 / 删除事件。
  ///
  /// 返回**写入失败的事件条数**（create/update 各自 try/catch 吞异常，失败
  /// 只计数不抛出 —— 个别失败不该让整个同步崩掉；但调用方要知道有没有
  /// 真写进去，否则 vivo 上选到只读日历会「假成功」）。
  Future<int> sync() async {
    final enabled = await isEnabled();
    if (!enabled) return 0;

    final calendarId = await getCalendarId();
    if (calendarId == null) return 0;

    await _migrateLegacyPrefsMap();

    final active = await _repo.getActiveSchedules();
    if (active == null) return 0;
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    final events = syncEventsFor(active.chain, from, syncDaysAhead);

    final byKey = <String, CalendarEventMappingRow>{};
    for (final m in await _repo.getCalendarEventMappings()) {
      byKey['${m.scheduleId}:${m.day}:${m.classId}:${m.seg}'] = m;
    }

    // 删除窗口外的映射（对应事件一并删掉，删不掉也要删映射 —— 留着会挡住重建）。
    for (final m in byKey.values) {
      final key = '${m.scheduleId}:${m.day}:${m.classId}:${m.seg}';
      if (events.any((e) => e.key == key)) continue;
      try {
        await DeviceCalendar.instance.deleteEvent(eventId: m.externalEventId);
      } catch (_) {}
      await _repo.deleteCalendarEventMapping(
          m.scheduleId, m.classId, m.day, m.seg);
    }

    // 创建 / 更新：无映射 → createEvent；有映射且指纹变了 → updateEvent。
    var failed = 0;
    for (final event in events) {
      final existing = byKey[event.key];
      if (existing != null) {
        if (existing.fingerprint == event.fingerprint) continue;
        try {
          await DeviceCalendar.instance.updateEvent(
            eventId: existing.externalEventId,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            description: event.description == null
                ? null
                : Patch.set(event.description!),
          );
          await _repo.saveCalendarEventMapping(
            scheduleId: existing.scheduleId,
            classId: existing.classId,
            day: existing.day,
            seg: existing.seg,
            externalEventId: existing.externalEventId,
            fingerprint: event.fingerprint,
          );
        } catch (_) {
          failed++;
        }
        continue;
      }
      final parts = event.key.split(':');
      try {
        final eventId = await DeviceCalendar.instance.createEvent(
          calendarId: calendarId,
          title: event.title,
          startDate: event.startDate,
          endDate: event.endDate,
          isAllDay: false,
          description: event.description,
        );
        await _repo.saveCalendarEventMapping(
          scheduleId: int.parse(parts[0]),
          classId: int.parse(parts[2]),
          day: int.parse(parts[1]),
          seg: int.parse(parts[3]),
          externalEventId: eventId,
          fingerprint: event.fingerprint,
        );
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// 一次性迁移：旧版把映射存在 prefs 的 JSON（键 `calendarSyncEventMap`）。
  ///
  /// 旧键没有 classId / seg，映射不到新的四元组上；旧事件按 eventId 删掉，
  /// 下一次 sync 会按新键重建。迁移后删掉 prefs 键，这条路径从此不再走。
  Future<void> _migrateLegacyPrefsMap() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_prefsKeyLegacyMap);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final v in decoded.values) {
          final eventId = v?.toString();
          if (eventId == null || eventId.isEmpty) continue;
          try {
            await DeviceCalendar.instance.deleteEvent(eventId: eventId);
          } catch (_) {}
        }
      }
    } catch (_) {}
    await sp.remove(_prefsKeyLegacyMap);
  }

  /// 检查是否启用同步。
  Future<bool> isEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_prefsKeyEnabled) ?? false;
  }

  /// 设置启用状态。
  Future<void> setEnabled(bool enabled) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_prefsKeyEnabled, enabled);
  }

  /// 获取日历提供者 ID。
  Future<String?> getCalendarId() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_prefsKeyCalendarId);
  }

  /// 保存选中的日历。
  Future<void> saveCalendarId(String calendarId) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefsKeyCalendarId, calendarId);
  }

  /// 自动同步用的日历名（用户 2026-10-25：不弹日历选择，自动建一个专属日历）。
  static const String appCalendarName = '倒班助手';

  /// 确保有「倒班助手」日历：已有就返回它的 id，没有就创建一个并记住。
  ///
  /// 创建失败（权限不足 / 账户限制）返回 null —— 调用方回落成「同步失败」。
  Future<String?> ensureCalendar() async {
    final existing = await getCalendarId();
    if (existing != null) return existing;
    final permission = await requestPermissions();
    if (!permission) return null;
    try {
      final calendarId = await DeviceCalendar.instance.createCalendar(
        name: appCalendarName,
        colorHex: '#1925AC', // 主色
      );
      if (calendarId.isNotEmpty) await saveCalendarId(calendarId);
      return calendarId.isNotEmpty ? calendarId : null;
    } catch (_) {
      // 创建日历失败（部分 ROM 不支持第三方建日历，如 vivo）：返回 null，
      // 调用方回退到「可选日历列表」而不是卡死。
      return null;
    }
  }

  /// 列出可用的日历。
  Future<List<Calendar>> listCalendars() async {
    final status = await DeviceCalendar.instance.hasPermissions();
    if (status == CalendarPermissionStatus.notDetermined) {
      await DeviceCalendar.instance.requestPermissions();
    }
    final result = await DeviceCalendar.instance.hasPermissions();
    if (result != CalendarPermissionStatus.granted) return [];
    return DeviceCalendar.instance.listCalendars();
  }

  /// 请求日历权限。
  Future<bool> requestPermissions() async {
    final status = await DeviceCalendar.instance.requestPermissions();
    return status == CalendarPermissionStatus.granted;
  }

  /// 一个时段的描述：「HH:mm-HH:mm」（钟面值；跨到次日的结束已减掉 1440）。
  static String buildSegmentDescription(ShiftSegment seg) {
    final e = seg.endMinute >= 1440 || seg.endMinute < seg.startMinute
        ? seg.endMinute % 1440
        : seg.endMinute;
    return '${formatClock(seg.startMinute)}-${formatClock(e)}';
  }
}

/// 一个待同步的日历事件。
class SyncEvent {
  const SyncEvent({
    required this.key,
    required this.title,
    required this.startDate,
    required this.endDate,
    this.description,
    required this.fingerprint,
  });

  /// 幂等键：`scheduleId:dayNumber:classId:seg`（同一天可有多个班次、一套方案
  /// 可有多个时段，三键会撞车）。
  final String key;
  final String title;
  final DateTime startDate;
  final DateTime endDate;
  final String? description;

  /// 内容指纹（key|title|startMs|endMs|desc）：与库里的映射不一致时 updateEvent，
  /// 一致时跳过 —— 修掉「班次改了时间，日历事件纹丝不动」。
  final String fingerprint;
}
