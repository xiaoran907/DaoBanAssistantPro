// app/test/payroll_repository_test.dart
//
// 薪资三张表的读写：设置（单例行）、按天日薪（day 主键）、发薪记录（年月主键）。
// 都是直接对仓库，不经过界面。重点在几条容易漏的语义：
//  ① 设置没落库时读回来是全 0，不是 null（引擎拿它直接算）；
//  ② 同一天 / 同一个月重复写是更新不是报错（insertOnConflictUpdate）；
//  ③ 清除那一天 / 那一个月本来就不存在时，什么都不做也不报错。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/data/app_repository.dart';
import 'package:shiftassistantpro/domain/payroll.dart';
import 'package:shiftassistantpro/domain/shift_rotation.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AppRepository(db);
  });
  tearDown(() => db.close());

  group('薪资设置', () {
    test('没存过 = 全 0（isUnset）', () async {
      final config = await repo.getPayrollConfig();
      expect(config.monthlyWage, 0);
      expect(config.isUnset, isTrue);
    });

    test('保存后读得回来；再保存是更新不是新增一行', () async {
      await repo.setPayrollConfig(
          const PayrollConfig(monthlyWage: 320));
      expect((await repo.getPayrollConfig()).monthlyWage, 320);

      await repo.setPayrollConfig(const PayrollConfig(monthlyWage: 350));
      final config = await repo.getPayrollConfig();
      expect(config.monthlyWage, 350);
      expect(config.isUnset, isFalse);

      final rows = await db.select(db.payrollSettingsRows).get();
      expect(rows, hasLength(1), reason: '单例行，永远只有一行');
    });

    test('watch 流跟着保存走', () async {
      final seen = <double>[];
      final sub = repo.watchPayrollConfig().listen((c) => seen.add(c.monthlyWage));
      await Future<void>.delayed(const Duration(milliseconds: 20)); // 等首帧
      await repo.setPayrollConfig(const PayrollConfig(monthlyWage: 320));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(seen.first, 0.0);
      expect(seen.last, 320.0);
    });
  });

  group('单日加项', () {
    test('设 / 改 / 清，dayNumber 口径一致', () async {
      final day = DateTime.utc(2025, 1, 6);
      await repo.setPayrollDayWage(day, 640);
      expect(await repo.listPayrollDayWages(),
          {dayNumber(day): closeTo(640, 0.001)});

      // 同一天重复设 = 更新。
      await repo.setPayrollDayWage(day, 960);
      expect((await repo.listPayrollDayWages())[dayNumber(day)], 960);

      // 带时分的日期落的是同一天（dateOnly 口径）。
      await repo.setPayrollDayWage(DateTime(2025, 1, 6, 23, 30), 500);
      expect((await repo.listPayrollDayWages())[dayNumber(day)], 500);

      await repo.clearPayrollDayWage(day);
      expect(await repo.listPayrollDayWages(), isEmpty);

      // 清一个本来就没设的天：不报错。
      await repo.clearPayrollDayWage(day);
    });
  });

  group('发薪记录', () {
    test('保存 / 更新 / 清除；actual 可空（只写备注）', () async {
      await repo.savePayrollRecord(
          year: 2025, month: 1, actual: 5120, note: '工资');
      await repo.savePayrollRecord(year: 2024, month: 12, actual: null, note: '漏发了');

      final records = await repo.listPayrollRecords();
      expect(records, hasLength(2));
      // 新的月份在前。
      expect(records.first.year, 2025);
      expect(records.first.actual, 5120);
      expect(records.last.year, 2024);
      expect(records.last.actual, isNull);
      expect(records.last.note, '漏发了');

      // 同月再存 = 更新。
      await repo.savePayrollRecord(year: 2025, month: 1, actual: 5000);
      final updated = await repo.listPayrollRecords();
      expect(updated.first.actual, 5000);
      expect(updated.first.note, isNull, reason: '没传备注 = 清掉');

      // 清除；清不存在的也安静。
      await repo.deletePayrollRecord(2025, 1);
      await repo.deletePayrollRecord(1999, 1);
      final left = await repo.listPayrollRecords();
      expect(left, hasLength(1));
    });

    test('watch 流按年月倒序', () async {
      await repo.savePayrollRecord(year: 2025, month: 1, actual: 1);
      await repo.savePayrollRecord(year: 2024, month: 12, actual: 2);

      final seen = <int>[];
      final sub = repo
          .watchPayrollRecords()
          .listen((rows) => seen.add(rows.first.year));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(seen, isNotEmpty);
      expect(seen.last, 2025);
    });
  });

  test('backup 清空重置也清薪资三张表', () async {
    await repo.setPayrollConfig(const PayrollConfig(monthlyWage: 320));
    await repo.setPayrollDayWage(DateTime.utc(2025, 1, 6), 640);
    await repo.savePayrollRecord(year: 2025, month: 1, actual: 5000);
    await repo.clearAll();

    final settings = await db.select(db.payrollSettingsRows).get();
    final days = await db.select(db.payrollDayRows).get();
    final records = await db.select(db.payrollRecordRows).get();
    expect(settings, isEmpty);
    expect(days, isEmpty);
    expect(records, isEmpty);
  });

  test('nullable real 列读回来不串类型', () async {
    await repo.savePayrollRecord(year: 2025, month: 2, actual: null, note: 'x');
    final row = (await db.select(db.payrollRecordRows).get()).single;
    expect(row.actual, isNull);
    expect(row.month, 2);
  });
}
