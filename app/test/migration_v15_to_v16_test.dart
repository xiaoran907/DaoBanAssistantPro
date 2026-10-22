// app/test/migration_v15_to_v16_test.dart
//
// v15 → v16：薪资统计。**纯新增**三张表（payroll_settings_rows /
// payroll_day_rows / payroll_record_rows），一行既有数据都不碰。
//
// 验法：先把**当前 schema 的库**建出来（onCreate），把 user_version 拨回 15、
// 删掉那三张新表模拟一个 v15 库，再让 AppDatabase 重开 —— 迁移分支会把三张表
// 建回来，既有的班次 / 待办数据原样不动。
import 'dart:io';

import 'package:drift/drift.dart' as drift show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/data/app_database.dart';

void main() {
  test('v15 → v16：三张薪资表建出来，既有数据不动', () async {
    final dir = await Directory.systemTemp.createTemp('migration_v16');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // ① 按**当前** schema 建一个库（onCreate 建全 15 张表）。
    final first = AppDatabase.forTesting(NativeDatabase(file));
    await first.customSelect('SELECT 1').getSingle();
    expect(first.schemaVersion, 16);

    // ② 模拟 v15：拨回版本号、删掉那三张新表。
    await first.customStatement('PRAGMA user_version = 15');
    await first.customStatement('DROP TABLE payroll_settings_rows');
    await first.customStatement('DROP TABLE payroll_day_rows');
    await first.customStatement('DROP TABLE payroll_record_rows');
    await first
        .into(first.shiftScheduleRows)
        .insert(ShiftScheduleRowsCompanion.insert(
          name: '旧库里的方案',
          anchorDate: DateTime.utc(2025, 1, 6),
        ));
    await first.close();

    // ③ 重开：drift 看到 user_version = 15 → 跑 from < 16 分支建回三张表。
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(reopened.schemaVersion, 16);

    final tables = await reopened
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'payroll%'")
        .get();
    final names = tables.map((r) => r.read<String>('name')).toSet();
    expect(names, containsAll(<String>[
      'payroll_settings_rows',
      'payroll_day_rows',
      'payroll_record_rows',
    ]));

    // ④ 既有数据一行不少。
    final schedules = await reopened.select(reopened.shiftScheduleRows).get();
    expect(schedules.single.name, '旧库里的方案');

    // ⑤ 新表可用：写一条薪资设置读回来。
    await reopened.into(reopened.payrollSettingsRows).insert(
          PayrollSettingsRowsCompanion.insert(id: const drift.Value(1)),
        );
    final settings = await reopened.select(reopened.payrollSettingsRows).get();
    expect(settings.single.id, 1);
    expect(settings.single.dailyWage, 0, reason: '默认 0，行为与升级前一致');
  });
}
