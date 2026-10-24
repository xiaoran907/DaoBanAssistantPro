// app/test/migration_v16_to_v17_test.dart
//
// v16 → v17：薪资模型改包月制。`payroll_settings_rows` 删 `daily_wage` /
// `daily_subsidy` 两列、加 `monthly_wage` 一列（表直接重建）；
// `payroll_day_rows` 清空（语义从「替换日薪」变「加项」，旧数据留下来会算飞）；
// `payroll_record_rows`（实发记录）不动。
//
// 验法：按当前 schema 建库 → 模拟 v16（拨回版本号 + 建回旧 schema 的
// payroll_settings_rows + 灌旧数据）→ 重开跑迁移 → 断言新列在、旧列没了、
// 单日加项表清空、实发记录原样。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' as drift show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/data/app_database.dart';

void main() {
  test('v16 → v17：月薪列建出、旧列删掉、加项表清空、实发记录不动', () async {
    final dir = await Directory.systemTemp.createTemp('migration_v17');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // ① 按当前 schema 建库。
    final first = AppDatabase.forTesting(NativeDatabase(file));
    await first.customSelect('SELECT 1').getSingle();
    expect(first.schemaVersion, 19);

    // ② 模拟 v16：拨回版本号，把 payroll_settings_rows 换成旧 schema
    //   （daily_wage / daily_subsidy），灌一条旧数据；再往单日加项表灌一条。
    await first.customStatement('PRAGMA user_version = 16');
    await first.customStatement('DROP TABLE IF EXISTS payroll_settings_rows');
    await first.customStatement(
      'CREATE TABLE payroll_settings_rows ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'daily_wage REAL NOT NULL DEFAULT 0, '
      'daily_subsidy REAL NOT NULL DEFAULT 0)',
    );
    await first.customStatement(
      'INSERT INTO payroll_settings_rows (daily_wage, daily_subsidy) '
      'VALUES (320, 10)',
    );
    await first.into(first.payrollDayRows).insert(
          PayrollDayRowsCompanion.insert(
            day: const drift.Value(19000),
            wage: 640,
          ),
        );
    // 实发记录：一条留着验「不动」。
    await first.into(first.payrollRecordRows).insert(
          PayrollRecordRowsCompanion.insert(
            year: 2025,
            month: 1,
            seq: 0,
            actual: const drift.Value(7800),
          ),
        );
    await first.close();

    // ③ 重开：drift 看到 user_version = 16 → 跑 from < 17 分支。
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(reopened.schemaVersion, 19);

    // ④ 新表 schema：有 wage，没有 monthly_wage / daily_wage / daily_subsidy。
    final cols = await reopened
        .customSelect("PRAGMA table_info('payroll_monthly_rows')")
        .get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    expect(names, contains('wage'));
    expect(names, isNot(contains('monthly_wage')));
    expect(names, isNot(contains('daily_wage')));
    expect(names, isNot(contains('daily_subsidy')));

    // ⑤ 新表默认值：月薪 0（老数据已清空，用户要重填）。
    final settings = await reopened.select(reopened.payrollMonthlyRows).get();
    expect(settings, isEmpty,
        reason: '旧行随表一起删掉，没有新行；界面据 isUnset 显示指路文案');

    // ⑥ 单日加项表保留（语义不变，不v清空）。
    final dayRows = await reopened.select(reopened.payrollDayRows).get();
    expect(dayRows, hasLength(1),
        reason: '单日加项表语义不变，保留原有数据');
    expect(dayRows.single.wage, 640);

    // ⑦ 实发记录原样（与薪资模型无关，不动）。
    final records = await reopened.select(reopened.payrollRecordRows).get();
    expect(records.single.actual, 7800);

    // ⑧ 新表可用：写一条月薪读回来。
    await reopened.into(reopened.payrollMonthlyRows).insert(
          PayrollMonthlyRowsCompanion.insert(
            year: 2025,
            month: 1,
            wage: const drift.Value(8000),
          ),
        );
    final after = await reopened.select(reopened.payrollMonthlyRows).get();
    expect(after.single.wage, 8000);
  });
}
