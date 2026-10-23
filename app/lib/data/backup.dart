// 全量备份：库（15 张表）+ 外观 / 铃声 prefs，进出一个 JSON 文件。
//
// 导入导出（设置 → 数据）与 WebDAV 云备份共用这一份编码 —— 两处各写一份
// 「哪些表进备份」迟早会漂，漂了就是「导出的备份恢复不回来」或「云端的备份
// 缺了薪资设置」这类静默缺斤短两。
//
// 格式（v1）：
// ```json
// {
//   "app": "shiftassistantpro",
//   "formatVersion": 1,
//   "schemaVersion": 16,
//   "appVersion": "0.12.2",
//   "exportedAt": 1761000000000,
//   "tables": { "shift_schedule_rows": [ {...}, ... ], ... },
//   "prefs": { "themeMode": "dark", ... }
// }
// ```
//
// 表行直接用 drift 生成的 `toJson()` / `fromJson()`（DateTime 走毫秒整数，
// JSON 安全且与库里的值逐字节对称）。**行里带主键**，恢复按 `insertOrReplace`
// 原样灌回 —— 班次定义的 id、覆盖表的 `{scheduleId, day}` 这些引用关系才能
// 一并保真。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_database.dart';

const String kBackupAppName = 'shiftassistantpro';
const int kBackupFormatVersion = 1;

/// 备份文件的文件名（导出与 WebDAV 上传共用）。
const String kBackupFileName = 'daoban-backup.json';

/// 备份不认识的格式 / 不是本应用的文件。
class BackupFormatException implements Exception {
  const BackupFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'BackupFormatException: $reason';
}

/// 备份来自更新的库结构（用户还没升级 App）。
class BackupTooNewException implements Exception {
  const BackupTooNewException(this.backupVersion);
  final int backupVersion;

  @override
  String toString() => 'BackupTooNewException: schema $backupVersion';
}

/// 备份里带外观 / 铃声的那几个 prefs 键。
///
/// **白名单，不是全部**：`onboarded` / `lastSeenVersion` / `lastUpdateCheckDay`
/// 是本机的流程状态（首启弹窗、更新检查节流），跟着备份走会把「新装机当成
/// 已看过介绍」；小组件快照键由 App 自己重推。WebDAV 的配置与密码**绝不进
/// 备份**（凭据不进一个可能被分享的文件）。
const List<String> kBackupPrefKeys = [
  'themeMode',
  'accentIndex',
  'language',
  'liquidGlass',
  'hapticsEnabled',
  'fontSize',
  'ringtoneUri',
  'ringtoneTitle',
  'snoozeMinutes',
];

Object? _prefValue(SharedPreferences sp, String key) {
  // 同一个键只可能有一种类型（写入方是同一个），按已知类型取。
  return switch (key) {
    'accentIndex' || 'snoozeMinutes' => sp.getInt(key),
    'liquidGlass' || 'hapticsEnabled' => sp.getBool(key),
    _ => sp.getString(key),
  };
}

Future<void> _restorePrefValue(
    SharedPreferences sp, String key, Object? value) async {
  if (value == null) {
    // 备份机上没设过 = 恢复成默认：把本机这个键抹掉。
    await sp.remove(key);
    return;
  }
  switch (value) {
    case final int v:
      await sp.setInt(key, v);
    case final bool v:
      await sp.setBool(key, v);
    case final String v:
      await sp.setString(key, v);
    default:
      // 类型对不上（手改过的文件）：跳过这一个键，不让整次恢复失败。
      break;
  }
}

/// 一张表的备份编解码：读（行 → JSON 列表）、写（JSON 列表 → 原样灌回）、清空。
///
/// 三个闭包各自显式写（不用泛型映射表）：drift 的行类型是每张表独立的类，
/// 泛型那一层反而要把类型擦掉再 cast 回来，直白写更短也更可读。
class _TableBackup {
  const _TableBackup({
    required this.name,
    required this.readJson,
    required this.writeRows,
  });

  final String name;
  final Future<List<Map<String, dynamic>>> Function() readJson;
  final Future<void> Function(List<Map<String, dynamic>> rows) writeRows;
}

/// 全部表的编解码清单。**加表必须来这里登记**，否则那张表的数据进不了备份
/// —— 导入后「刚备份过却丢了数据」就是这么来的。
List<_TableBackup> _tableBackups(AppDatabase db) => [
      _TableBackup(
        name: 'shift_schedule_rows',
        readJson: () async => [
          for (final r
              in await (db.select(db.shiftScheduleRows)
                    ..orderBy([(t) => OrderingTerm.asc(t.id)]))
                  .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.shiftScheduleRows).insert(
                  ShiftScheduleRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'schedule_span_rows',
        readJson: () async => [
          for (final r in await (db.select(db.scheduleSpanRows)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.scheduleSpanRows).insert(
                  ScheduleSpanRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'shift_class_rows',
        readJson: () async => [
          for (final r in await (db.select(db.shiftClassRows)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.shiftClassRows).insert(
                  ShiftClassRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'shift_cycle_rows',
        readJson: () async => [
          for (final r in await (db.select(db.shiftCycleRows)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.shiftCycleRows).insert(
                  ShiftCycleRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'schedule_month_segment_rows',
        readJson: () async => [
          for (final r in await (db.select(db.scheduleMonthSegmentRows)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.scheduleMonthSegmentRows).insert(
                  ScheduleMonthSegmentRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'shift_class_alarms',
        readJson: () async => [
          for (final r in await (db.select(db.shiftClassAlarms)
                ..orderBy([(t) => OrderingTerm.asc(t.classId)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.shiftClassAlarms).insert(
                  ShiftClassAlarm.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'schedule_events',
        readJson: () async => [
          for (final r in await (db.select(db.scheduleEvents)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.scheduleEvents).insert(
                  ScheduleEvent.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'custom_alarms',
        readJson: () async => [
          for (final r in await (db.select(db.customAlarms)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.customAlarms).insert(
                  CustomAlarm.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'shift_alarm_overrides',
        readJson: () async => [
          for (final r in await (db.select(db.shiftAlarmOverrides)
                ..orderBy([(t) => OrderingTerm.asc(t.day)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.shiftAlarmOverrides).insert(
                  ShiftAlarmOverride.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'shift_day_overrides',
        readJson: () async => [
          for (final r in await (db.select(db.shiftDayOverrides)
                ..orderBy([(t) => OrderingTerm.asc(t.day)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.shiftDayOverrides).insert(
                  ShiftDayOverride.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'custom_templates',
        readJson: () async => [
          for (final r in await (db.select(db.customTemplates)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.customTemplates).insert(
                  CustomTemplate.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'recurring_series_rows',
        readJson: () async => [
          for (final r in await (db.select(db.recurringSeriesRows)
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.recurringSeriesRows).insert(
                  RecurringSeriesRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'payroll_monthly_rows',
        readJson: () async => [
          for (final r in await db.select(db.payrollMonthlyRows).get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.payrollMonthlyRows).insert(
                  PayrollMonthlyRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'payroll_day_rows',
        readJson: () async => [
          for (final r in await (db.select(db.payrollDayRows)
                ..orderBy([(t) => OrderingTerm.asc(t.day)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.payrollDayRows).insert(
                  PayrollDayRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
      _TableBackup(
        name: 'payroll_record_rows',
        readJson: () async => [
          for (final r in await (db.select(db.payrollRecordRows)
                ..orderBy([(t) => OrderingTerm.asc(t.year)]))
              .get())
            r.toJson(),
        ],
        writeRows: (rows) async {
          for (final j in rows) {
            await db.into(db.payrollRecordRows).insert(
                  PayrollRecordRow.fromJson(j),
                  mode: InsertMode.insertOrReplace,
                );
          }
        },
      ),
    ];

/// 把当前库 + prefs 编成备份 JSON（已 `jsonEncode` 过的字符串）。
Future<String> buildBackupJson(AppDatabase db,
    {SharedPreferences? prefs, required String appVersion}) async {
  final tables = <String, Object?>{};
  for (final codec in _tableBackups(db)) {
    tables[codec.name] = await codec.readJson();
  }
  final prefsSection = <String, Object?>{};
  if (prefs != null) {
    for (final key in kBackupPrefKeys) {
      prefsSection[key] = _prefValue(prefs, key);
    }
  }
  return jsonEncode(<String, Object?>{
    'app': kBackupAppName,
    'formatVersion': kBackupFormatVersion,
    'schemaVersion': db.schemaVersion,
    'appVersion': appVersion,
    'exportedAt': DateTime.now().millisecondsSinceEpoch,
    'tables': tables,
    'prefs': prefsSection,
  });
}

/// 校验并解析备份文本（不写库）。导入与 WebDAV 拉取共用这一个入口。
///
/// 返回 `(tables, prefs)`：tables 的键是表名、值是行 JSON 列表；prefs 是白名单
/// 键的原生值。抛 [BackupFormatException] / [BackupTooNewException]。
({Map<String, List<Map<String, dynamic>>> tables, Map<String, Object?> prefs})
    parseBackupJson(String text, {required int currentSchemaVersion}) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw BackupFormatException('不是 JSON：${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const BackupFormatException('顶层不是对象');
  }
  if (decoded['app'] != kBackupAppName) {
    throw const BackupFormatException('不是本应用的备份');
  }
  if (decoded['formatVersion'] != kBackupFormatVersion) {
    throw BackupFormatException('不支持的格式版本：${decoded['formatVersion']}');
  }
  final schema = decoded['schemaVersion'];
  if (schema is! int) {
    throw const BackupFormatException('缺 schemaVersion');
  }
  if (schema > currentSchemaVersion) {
    throw BackupTooNewException(schema);
  }
  final rawTables = decoded['tables'];
  if (rawTables is! Map<String, dynamic>) {
    throw const BackupFormatException('缺 tables');
  }
  final tables = <String, List<Map<String, dynamic>>>{};
  rawTables.forEach((name, rows) {
    if (rows is! List) {
      throw BackupFormatException('表 $name 的行不是列表');
    }
    tables[name] = [
      for (final r in rows)
        if (r is Map<String, dynamic>) r,
    ];
  });
  final prefs = <String, Object?>{};
  final rawPrefs = decoded['prefs'];
  if (rawPrefs is Map<String, dynamic>) {
    for (final key in kBackupPrefKeys) {
      if (rawPrefs.containsKey(key)) prefs[key] = rawPrefs[key];
    }
  }
  return (tables: tables, prefs: prefs);
}

/// 从解析过的备份恢复：**先清空全部表再灌回**（一个事务）。
///
/// 注意与 `AppRepository.clearAll` 的差别：那个是「重置」（清完重新播种默认
/// 方案），这个是「换数据」（灌备份自己的行，**不播种** —— 备份里没有方案时
/// 就该是空库）。prefs 由调用方另行恢复（要在外层跑 AppSettings 的重载）。
Future<void> restoreParsedBackup(
  AppDatabase db,
  Map<String, List<Map<String, dynamic>>> tables,
) async {
  final codecs = _tableBackups(db);
  await db.transaction(() async {
    // 先全部清空（不论备份里有没有这张表的数据）再灌回：备份里没有的表
    // 就该是空的，残留本机旧行等于「恢复了个混合体」。
    for (final codec in codecs) {
      await db.customStatement('DELETE FROM ${codec.name}');
    }
    for (final codec in codecs) {
      await codec.writeRows(tables[codec.name] ?? const []);
    }
  });
}

/// 恢复 prefs 白名单（导入 / 云端恢复共用）。
Future<void> restoreBackupPrefs(
    SharedPreferences sp, Map<String, Object?> prefs) async {
  for (final key in kBackupPrefKeys) {
    if (prefs.containsKey(key)) {
      await _restorePrefValue(sp, key, prefs[key]);
    }
  }
}
