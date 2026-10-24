import 'dart:convert';

import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/app_repository.dart';
import '../../domain/shift_rotation.dart';

/// 日历同步服务：单向推送排班到系统日历（D19~D24）。
///
/// 幂等映射：App 端存 `scheduleId:day → eventId`，增量更新不产生大量「删建」痕迹。
class CalendarSyncService {
  CalendarSyncService(this._repo);

  final AppRepository _repo;

  static const String _prefsKeyMap = 'calendarSyncEventMap';
  static const String _prefsKeyCalendarId = 'calendarSyncCalendarId';
  static const String _prefsKeyEnabled = 'calendarSyncEnabled';
  static const int syncDaysAhead = 60;

  /// 生成未来 [days] 天的班次实例列表。
  Future<List<SyncEvent>> _generateFutureEvents() async {
    final active = await _repo.getActiveSchedules();
    if (active == null) return [];

    final chain = active.chain;
    final now = DateTime.now();
    final startDate = DateTime(now.year, now.month, now.day);
    final endDate = startDate.add(const Duration(days: syncDaysAhead));

    final events = <SyncEvent>[];
    final totalDays = endDate.difference(startDate).inDays;

    for (var i = 0; i <= totalDays; i++) {
      final date = startDate.add(Duration(days: i));
      final dayNum = dayNumber(date);

      final schedule = chain.scheduleOn(date);
      if (schedule == null) continue;

      final shifts = schedule.shiftOn(date);
      for (final shift in shifts) {
        if (shift.isRest) continue;
        if (shift.startMinute == null || shift.endMinute == null) continue;

        final startMin = shift.startMinute!;
        final endMin = shift.endMinute!;

        final startTime = DateTime(date.year, date.month, date.day,
            startMin ~/ 60, startMin % 60);
        DateTime endTime;
        if (endMin > startMin && endMin - startMin < 1440) {
          endTime = DateTime(date.year, date.month, date.day,
              endMin ~/ 60, endMin % 60);
        } else {
          final nextDay = date.add(const Duration(days: 1));
          endTime = DateTime(nextDay.year, nextDay.month, nextDay.day,
              endMin ~/ 60, endMin % 60);
        }

        final scheduleId = chain.scheduleIdOn(date) ?? 0;
        final key = '$scheduleId:$dayNum';
        events.add(SyncEvent(
          key: key,
          title: shift.name,
          startDate: startTime,
          endDate: endTime,
          description: _buildDescription(shift),
        ));
      }
    }

    return events;
  }

  /// 同步到系统日历：创建/更新/删除事件。
  Future<void> sync() async {
    final enabled = await isEnabled();
    if (!enabled) return;

    final calendarId = await getCalendarId();
    if (calendarId == null) return;

    final futureEvents = await _generateFutureEvents();
    final map = await _loadMap();

    final futureKeys = futureEvents.map((e) => e.key).toSet();
    final existingKeys = map.keys.toSet();

    // 删除不在未来 60 天范围内的事件
    final keysToDelete = existingKeys.difference(futureKeys).toList();
    for (final key in keysToDelete) {
      final eventId = map[key];
      if (eventId != null) {
        try {
          await DeviceCalendar.instance.deleteEvent(eventId: eventId);
        } catch (_) {}
      }
      map.remove(key);
    }

    // 创建新事件
    for (final event in futureEvents) {
      if (map.containsKey(event.key)) continue;
      try {
        final eventId = await DeviceCalendar.instance.createEvent(
          calendarId: calendarId,
          title: event.title,
          startDate: event.startDate,
          endDate: event.endDate,
          isAllDay: false,
          description: event.description,
        );
        map[event.key] = eventId;
      } catch (_) {}
    }

    await _saveMap(map);
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

  Future<Map<String, String>> _loadMap() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_prefsKeyMap);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  Future<void> _saveMap(Map<String, String> map) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefsKeyMap, jsonEncode(map));
  }

  String _buildDescription(ShiftClass shift) {
    final parts = <String>[];
    if (shift.startMinute != null && shift.endMinute != null) {
      parts.add(
          '${formatClock(shift.startMinute!)}-${formatClock(shift.endMinute!)}');
    }
    return parts.join(' ');
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
  });

  /// 幂等键：`scheduleId:dayNumber`。
  final String key;
  final String title;
  final DateTime startDate;
  final DateTime endDate;
  final String? description;
}
