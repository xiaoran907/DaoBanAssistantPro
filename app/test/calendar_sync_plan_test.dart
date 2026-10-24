// app/test/calendar_sync_plan_test.dart
//
// 日历同步的「事件清单」—— 顶层纯函数 `syncEventsFor`。
//
// 钉住四件事：幂等键是**四元组** `scheduleId:dayNumber:classId:seg`（同一天
// 可有多个班次、一套方案可有多个时段，三键会撞车）；多段班次每段独立一条；
// 回绕表示（20:00–06:30 存成 1200→390）的结束落在次日；**内容指纹**随时间
// 变化（指纹不变 updateEvent 不触发，日历事件就纹丝不动）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/data/app_repository.dart';
import 'package:shiftassistantpro/domain/shift_rotation.dart';
import 'package:shiftassistantpro/features/calendar/calendar_sync_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

AppDatabase _db() {
  final raw = sqlite3.sqlite3.openInMemory();
  final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
  addTearDown(db.close);
  return db;
}

Future<int> _save(
  AppRepository repo, {
  required List<ShiftClass> classes,
  int? scheduleId,
}) =>
    repo.saveSchedule(
      scheduleId: scheduleId,
      name: 'A',
      anchorDate: DateTime.utc(2026, 1, 1),
      classes: classes,
      cycle: const [[0]],
      makeCurrent: true,
      teamCount: 1,
      teamNames: const ['我'],
      teamOffsets: const [0],
    );

void main() {
  test('幂等键是四元组 scheduleId:dayNumber:classId:seg', () async {
    final repo = AppRepository(_db());
    final aId = await _save(repo, classes: [
      const ShiftClass(name: '白班', startMinute: 480, endMinute: 1080),
    ]);
    final chain = (await repo.getActiveSchedules())!.chain;
    final events =
        CalendarSyncService.syncEventsFor(chain, DateTime(2026, 9, 20), 1);
    expect(events, hasLength(1));
    final e = events.single;
    final parts = e.key.split(':');
    expect(parts, hasLength(4));
    expect(int.parse(parts[0]), aId);
    expect(int.parse(parts[1]), dayNumber(DateTime(2026, 9, 20)));
    expect(parts[3], '0');
    expect(e.title, '白班');
    expect(e.startDate, DateTime(2026, 9, 20, 8));
    expect(e.endDate, DateTime(2026, 9, 20, 18));
    expect(e.description, '08:00-18:00');
  });

  test('多段班次每段一条；回绕表示的结束落在次日', () async {
    final repo = AppRepository(_db());
    await _save(repo, classes: [
      const ShiftClass(
          name: '两段',
          startMinute: 480,
          endMinute: 1080,
          extraSegments: [ShiftSegment(1200, 390)]),
    ]);
    final chain = (await repo.getActiveSchedules())!.chain;
    final events =
        CalendarSyncService.syncEventsFor(chain, DateTime(2026, 9, 20), 1);
    expect(events, hasLength(2));
    expect(events[0].key.endsWith(':0'), isTrue);
    expect(events[1].key.endsWith(':1'), isTrue);
    expect(events[1].startDate, DateTime(2026, 9, 20, 20));
    expect(events[1].endDate, DateTime(2026, 9, 21, 6, 30),
        reason: '回绕表示（end < start）的结束落在次日');
    expect(events[1].description, '20:00-06:30');
  });

  test('班次时间变了指纹跟着变，key 不变', () async {
    final repo = AppRepository(_db());
    final aId = await _save(repo, classes: [
      const ShiftClass(name: '白班', startMinute: 480, endMinute: 1080),
    ]);
    final chain = (await repo.getActiveSchedules())!.chain;
    final first =
        CalendarSyncService.syncEventsFor(chain, DateTime(2026, 9, 20), 1)
            .single;
    final classId = int.parse(first.key.split(':')[2]);

    // 同 id 增量更新：结束 18:00 → 19:00（同一套方案，不新建）。
    await _save(repo, scheduleId: aId, classes: [
      ShiftClass(
          id: classId, name: '白班', startMinute: 480, endMinute: 1140),
    ]);
    final chain2 = (await repo.getActiveSchedules())!.chain;
    final second =
        CalendarSyncService.syncEventsFor(chain2, DateTime(2026, 9, 20), 1)
            .single;

    expect(second.key, first.key, reason: '班次 id 没变，四元键就不变');
    expect(second.fingerprint, isNot(first.fingerprint),
        reason: '时间变了指纹必须变，否则 updateEvent 不触发');
  });

  test('休班没有事件', () async {
    final repo = AppRepository(_db());
    await _save(repo, classes: [
      const ShiftClass(name: '休', isRest: true),
    ]);
    final chain = (await repo.getActiveSchedules())!.chain;
    final events =
        CalendarSyncService.syncEventsFor(chain, DateTime(2026, 9, 20), 1);
    expect(events, isEmpty);
  });
}
