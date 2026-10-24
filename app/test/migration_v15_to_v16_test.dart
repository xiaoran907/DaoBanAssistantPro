// app/test/migration_v15_to_v16_test.dart
//
// v15 → v16：班次多时段。**纯新增** —— `shift_class_rows` 一列
// （`extra_segments`，TEXT 默认空串），既有数据一行不碰。
//
// 这条用例盯的是**两条开发线合流后的那一条真实升级路径**：v15 是上游 v0.12.3
// （2026-10-22）停下的位置 —— 重复待办已经有 `month_days` / `shift_names`
// 那一对列，而「班次多时段」还没到（它是合流后本分支占的 16）。所以 fixture
// 建的是 **v0.12.3 的形态**：`recurring_series_rows` 两列俱全、没有
// `extra_segments`。
//
// 三条最要紧的断言：
//  ① **老库逐项不变** —— 既有班次全部读回单段班次（`extraSegments` 空表），
//     引擎、闹钟、日历的行为与升级前逐字节相同。
//  ② **新列可写可读** —— 编码过的时段串读回领域层能还原成段列表。
//  ③ **15 那一段不会被重跑** —— 重复待办的两列原样（`month_days` 还在、
//     `month_day` 已经没了）。把 16 段错留在 15 上会漏掉 `extra_segments`
//     （`no such column`），而把 15 段跑到 v0.12.3 库上会 `duplicate column`。
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/data/app_repository.dart';
import 'package:shiftassistantpro/domain/shift_rotation.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v15 形态的建表 DDL（= 上游 v0.12.3 停下的位置，与那一版的生成代码逐列一致）：
/// 班次表还没有 `extra_segments`，重复待办表已经是 `month_days` / `shift_names`
/// 那一对（不再是单日 `month_day`）。
const _v15Schema = [
  '''
CREATE TABLE shift_schedule_rows (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  anchor_date INTEGER NOT NULL,
  is_current INTEGER NOT NULL DEFAULT 0,
  team_count INTEGER NOT NULL DEFAULT 4,
  team_names TEXT NOT NULL DEFAULT '一班,二班,三班,四班',
  our_team_index INTEGER NOT NULL DEFAULT 0,
  team_offsets TEXT NOT NULL DEFAULT '',
  monthly INTEGER NOT NULL DEFAULT 0,
  team_seg_offsets TEXT NOT NULL DEFAULT ''
)
''',
  '''
CREATE TABLE schedule_span_rows (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  schedule_id INTEGER NOT NULL,
  start_date INTEGER,
  end_date INTEGER
)
''',
  '''
CREATE TABLE shift_class_rows (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  schedule_id INTEGER NOT NULL,
  "order" INTEGER NOT NULL,
  name TEXT NOT NULL,
  abbr TEXT,
  start_minute INTEGER,
  end_minute INTEGER,
  is_rest INTEGER NOT NULL DEFAULT 0,
  color INTEGER NOT NULL DEFAULT 4284186623,
  alarm_enabled INTEGER NOT NULL DEFAULT 0
)
''',
  '''
CREATE TABLE shift_cycle_rows (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  schedule_id INTEGER NOT NULL,
  "order" INTEGER NOT NULL,
  class_id INTEGER NOT NULL
)
''',
  '''
CREATE TABLE shift_class_alarms (
  class_id INTEGER NOT NULL,
  "order" INTEGER NOT NULL,
  minute INTEGER NOT NULL,
  label TEXT,
  PRIMARY KEY (class_id, "order")
)
''',
  '''
CREATE TABLE shift_day_overrides (
  schedule_id INTEGER NOT NULL,
  day INTEGER NOT NULL,
  class_id INTEGER NOT NULL,
  PRIMARY KEY (schedule_id, day)
)
''',
  '''
CREATE TABLE custom_templates (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  classes TEXT NOT NULL,
  cycle TEXT NOT NULL,
  team_count INTEGER NOT NULL,
  team_offsets TEXT NOT NULL,
  monthly INTEGER NOT NULL DEFAULT 0,
  month_segments TEXT NOT NULL DEFAULT '',
  team_seg_offsets TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
)
''',
  '''
CREATE TABLE recurring_series_rows (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  time_minute INTEGER NULL,
  advance_remind_minutes INTEGER NULL,
  alarm_enabled INTEGER NOT NULL DEFAULT 0,
  repeat_type INTEGER NOT NULL DEFAULT 0,
  weekdays INTEGER NOT NULL DEFAULT 0,
  month_days INTEGER NOT NULL DEFAULT 0,
  shift_names TEXT NULL,
  start_date INTEGER NOT NULL,
  skip_through INTEGER NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
)
''',
];

int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

/// 开一个 v15 库（上游 v0.12.3 的形态），种一套「四班两倒」形态的方案
/// （班次 + 周期 + 一条闹钟）与一条「每月 15 号」的重复待办。
Future<AppDatabase> _openV15() async {
  final raw = sqlite3.sqlite3.openInMemory();
  for (final ddl in _v15Schema) {
    raw.execute(ddl);
  }

  raw.execute(
    'INSERT INTO shift_schedule_rows '
    '(id, name, anchor_date, is_current, team_count, team_names, '
    'our_team_index, team_offsets) VALUES (1, ?, ?, 1, 4, ?, 1, ?)',
    [
      '炼油三部 · 四班两倒',
      _sec(DateTime.utc(2026, 1, 6)),
      '一班,二班,三班,四班',
      '0,1,2,3',
    ],
  );

  raw.execute(
    'INSERT INTO shift_class_rows '
    '(id, schedule_id, "order", name, abbr, start_minute, end_minute, '
    'is_rest, color, alarm_enabled) VALUES (1, 1, 0, ?, ?, 510, 1230, 0, ?, 1)',
    ['白班', '白', 0xFF4C8DFF],
  );
  raw.execute(
    'INSERT INTO shift_class_rows '
    '(id, schedule_id, "order", name, abbr, start_minute, end_minute, '
    'is_rest, color, alarm_enabled) VALUES (2, 1, 1, ?, ?, 1230, 510, 0, ?, 1)',
    ['夜班', '夜', 0xFF7A5CFF],
  );

  raw.execute('INSERT INTO shift_cycle_rows (schedule_id, "order", class_id) '
      'VALUES (1, 0, 1), (1, 1, 2)');

  raw.execute(
      'INSERT INTO shift_class_alarms (class_id, "order", minute, label) '
      'VALUES (1, 0, 420, ?)',
      ['起床']);

  raw.execute(
    'INSERT INTO recurring_series_rows '
    '(id, title, time_minute, advance_remind_minutes, alarm_enabled, '
    'repeat_type, weekdays, month_days, shift_names, start_date, '
    'skip_through, enabled, created_at) '
    'VALUES (1, ?, 540, 0, 1, 2, 0, ?, NULL, ?, NULL, 1, ?)',
    [
      '每月 15 号',
      1 << 14,
      _sec(DateTime.utc(2026, 1, 15)),
      _sec(DateTime.utc(2026, 1, 1)),
    ],
  );

  raw.execute('PRAGMA user_version = 15');
  return AppDatabase.forTesting(NativeDatabase.opened(raw));
}

void main() {
  test('v15 → 最新：老班次读回单段班次，新列可写可读，15 那段不重跑', () async {
    final db = await _openV15();
    addTearDown(db.close);

    expect(db.schemaVersion, 20);

    // ① 老行带着默认值到位：extra_segments = ''，领域层读回单段班次
    final rows = await (db.select(db.shiftClassRows)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    expect(rows.map((c) => c.name), ['白班', '夜班']);
    expect(rows.map((c) => c.extraSegments), ['', '']);
    final domains = rows.map((c) => c.toDomain()).toList();
    expect(domains.map((c) => c.extraSegments), [[], []]);
    expect(domains.map((c) => c.allSegments.length), [1, 1]);
    expect(domains[0].startMinute, 510);
    expect(domains[0].endMinute, 1230);

    // ② 新列可写可读：编码过的时段串还原成段列表
    await (db.update(db.shiftClassRows)..where((t) => t.id.equals(2))).write(
      const ShiftClassRowsCompanion(
        extraSegments: Value('600-720,1200-1320'),
      ),
    );
    final updated =
        await (db.select(db.shiftClassRows)..where((t) => t.id.equals(2)))
            .getSingle();
    expect(updated.extraSegments, '600-720,1200-1320');
    final segment = updated.toDomain();
    expect(segment.extraSegments.length, 2);
    expect(segment.extraSegments[0], const ShiftSegment(600, 720));
    expect(segment.extraSegments[1], const ShiftSegment(1200, 1320));
    expect(segment.allSegments.length, 3);

    // ③ 15 那段没被重跑：重复待办仍是一行、两列原样、旧列也没回来
    final series = await db.select(db.recurringSeriesRows).getSingle();
    expect(series.monthDays, 1 << 14);
    expect(series.shiftNames, isNull);
    expect(series.timeMinute, 540);
    final recurringCols = await db
        .customSelect('PRAGMA table_info(recurring_series_rows)')
        .get();
    final names = recurringCols.map((c) => c.data['name']).toList();
    expect(names, contains('month_days'));
    expect(names, contains('shift_names'));
    expect(names, isNot(contains('month_day')));

    // ④ 16 之后的各段也都跑到了：薪资两张表与日历映射表都在（v0.12.3 的库里
    // 它们一张都没有）
    expect(await db.select(db.payrollDayRows).get(), isEmpty);
    expect(await db.select(db.payrollMonthlyRows).get(), isEmpty);
    expect(await db.select(db.calendarEventMappingRows).get(), isEmpty);
  });
}
