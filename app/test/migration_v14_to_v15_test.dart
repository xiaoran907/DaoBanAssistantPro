// app/test/migration_v14_to_v15_test.dart
//
// v14 → v15：重复待办加 `month_days` / `shift_names`，把旧的单日 `month_day`
// 迁进位掩码后删列。
//
// 三条最要紧的断言：
//  ① 每月的行**带上迁移后的掩码**（15 号 → 第 15 位）；
//  ② 每天 / 每周的行 `month_days` 为 0，其余字段原样；
//  ③ `month_day` 列真的没了（不留死列）。
//
// ⚠️ 这一段迁移必须排在 `from < 11` 之前，而 recurring_series_rows 是
// `from < 11` 那段才建的 —— 所以实现里有 `from >= 11` 守卫。本文件只从 v14 升，
// 守卫的另一半由 `migration_v13_to_v14_test.dart` / `migration_v10_to_v14_test.dart`
// 那一批（从更早版本升上来）兜住。
//
// ⚠️ **fixture 得建两张表**：从 v14 升上来时，除了上面那段，合并进来的
// `from < 16`（班次多时段）也会跑（分支按倒序跑，14 落在 16 之下），它要
// `addColumn shift_class_rows.extra_segments` —— 真实 v14 库有这张表，fixture
// 就得有，否则 `no such table: shift_class_rows`。更上面的 17 / 19 / 20 三段
// 只 `createTable`（drift 发的是 IF NOT EXISTS）或 `DROP … IF EXISTS`。
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/data/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v14 形态的 `recurring_series_rows` DDL（与 v14 的生成代码逐列一致）——
/// `from < 15` 那段会重新建它（加两列、删 `month_day`）。
const _v14RecurringSchema = '''
CREATE TABLE recurring_series_rows (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  time_minute INTEGER NULL,
  advance_remind_minutes INTEGER NULL,
  alarm_enabled INTEGER NOT NULL DEFAULT 0,
  repeat_type INTEGER NOT NULL DEFAULT 0,
  weekdays INTEGER NOT NULL DEFAULT 0,
  month_day INTEGER NOT NULL DEFAULT 1,
  start_date INTEGER NOT NULL,
  skip_through INTEGER NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
)
''';

/// v14 形态的 `shift_class_rows`（还没有 `extra_segments`）—— `from < 16` 那段
/// 会 `addColumn`，fixture 不建它就 `no such table`。
const _v14ShiftClassSchema = '''
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
''';

int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

Future<AppDatabase> _openV14() async {
  final raw = sqlite3.sqlite3.openInMemory();
  raw.execute(_v14RecurringSchema);
  raw.execute(_v14ShiftClassSchema);

  // 每月 15 号 / 每天 / 每周一 三条系列。
  raw.execute(
    'INSERT INTO recurring_series_rows '
    '(id, title, time_minute, advance_remind_minutes, alarm_enabled, '
    'repeat_type, weekdays, month_day, start_date, skip_through, enabled, '
    'created_at) VALUES (1, ?, 540, 0, 1, 2, 0, 15, ?, NULL, 1, ?)',
    ['每月 15 号', _sec(DateTime.utc(2026, 1, 15)), _sec(DateTime.utc(2026, 1, 1))],
  );
  raw.execute(
    'INSERT INTO recurring_series_rows '
    '(id, title, time_minute, advance_remind_minutes, alarm_enabled, '
    'repeat_type, weekdays, month_day, start_date, skip_through, enabled, '
    'created_at) VALUES (2, ?, 480, NULL, 0, 0, 0, 1, ?, NULL, 1, ?)',
    ['每天', _sec(DateTime.utc(2026, 2, 1)), _sec(DateTime.utc(2026, 1, 2))],
  );
  raw.execute(
    'INSERT INTO recurring_series_rows '
    '(id, title, time_minute, advance_remind_minutes, alarm_enabled, '
    'repeat_type, weekdays, month_day, start_date, skip_through, enabled, '
    'created_at) VALUES (3, ?, NULL, NULL, 0, 1, 2, 1, ?, ?, 0, ?)',
    ['每周一', _sec(DateTime.utc(2026, 3, 1)), 0, _sec(DateTime.utc(2026, 1, 3))],
  );

  raw.execute('PRAGMA user_version = 14');
  return AppDatabase.forTesting(NativeDatabase.opened(raw));
}

void main() {
  test('v14 → v15：month_day 迁成 month_days 位掩码，旧列删除，其余原样', () async {
    final db = await _openV14();
    addTearDown(db.close);

    final rows = await (db.select(db.recurringSeriesRows)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    expect(rows.length, 3);

    // ① 每月 15 号 → 第 15 位；每天 / 每周为 0
    expect(rows[0].monthDays, 1 << 14);
    expect(rows[1].monthDays, 0);
    expect(rows[2].monthDays, 0);

    // ② 新列默认空；其余字段原样
    expect(rows.every((r) => r.shiftNames == null), isTrue);
    expect(rows[0].title, '每月 15 号');
    expect(rows[0].timeMinute, 540);
    expect(rows[0].advanceRemindMinutes, 0);
    expect(rows[0].alarmEnabled, isTrue);
    expect(rows[1].advanceRemindMinutes, isNull);
    expect(rows[1].alarmEnabled, isFalse);
    expect(rows[2].weekdays, 2);
    expect(rows[2].skipThrough, 0);
    expect(rows[2].enabled, isFalse);

    // ③ 旧列真的删掉了（不留死列）
    final cols = await db
        .customSelect('PRAGMA table_info(recurring_series_rows)')
        .get();
    final names = cols.map((c) => c.data['name']).toList();
    expect(names, isNot(contains('month_day')));
    expect(names, contains('month_days'));
    expect(names, contains('shift_names'));
  });
}
