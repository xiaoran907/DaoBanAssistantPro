// app/test/stats_screen_test.dart
//
// 统计页的界面行为：金额卡按班表现算、按日出勤可单独改钱、发薪记录可记可清。
// 数据口径在 `payroll_engine_test` / `payroll_repository_test` 里钉过，这里钉
// 「界面把它摆对了 + 改完立刻重算」。
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:shiftassistantpro/core/l10n.dart';
import 'package:shiftassistantpro/data/app_repository.dart';
import 'package:shiftassistantpro/domain/payroll.dart';
import 'package:shiftassistantpro/domain/shift_rotation.dart';
import 'package:shiftassistantpro/features/stats/stats_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('zh');
    drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  late AppDatabase db;
  late AppRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    L10n.locale = 'zh';
    db = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite3.sqlite3.openInMemory()));
    repo = AppRepository(db);
    await repo.ensureSeeded();
    // 给一笔看得见的账：日薪 320 / 补助 10。
    await repo.setPayrollConfig(
        const PayrollConfig(dailyWage: 320, dailySubsidy: 10));
  });
  tearDown(() => db.close());

  Future<void> pumpScreen(WidgetTester tester,
      {Size size = const Size(420, 1400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: StatsScreen()),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// 拆树 + 让 drift 那个零时长清理定时器跑完 —— 不做的话用例结束时
  /// 「有 pending timer」直接红（calendar_screen_test 的 `_disposeCalendar` 同一条）。
  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  testWidgets('应发合计与按班次统计跟着班表走', (tester) async {
    await pumpScreen(tester);

    // 2025 年锚点的四班两倒落到 2026-10：出勤 16 天（本月按链逐天算）。
    // 这里不硬编码总天数 —— 钉的是「应发 = 出勤 × 330」这条恒等式。
    final month = computeMonthPay(
      (await repo.getActiveSchedules())!.chain,
      DateTime.now(),
      const PayrollConfig(dailyWage: 320, dailySubsidy: 10),
      const {},
    );
    // 金额卡上那行就是现算的总额（同一口径的 moneyText）。
    expect(find.text(moneyText(month.total)), findsOneWidget);
    expect(find.byKey(const Key('stats-by-shift')), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('按日出勤里点一天改钱，应发立刻重算', (tester) async {
    final monthBefore = computeMonthPay(
      (await repo.getActiveSchedules())!.chain,
      DateTime.now(),
      const PayrollConfig(dailyWage: 320, dailySubsidy: 10),
      const {},
    );
    if (monthBefore.days.isEmpty) {
      // 本月没有出勤（理论上种子方案总有）—— 换个前提就跳过，别造假绿。
      return;
    }
    // 取第一个出勤日（今天可能恰好是休班，行不在列表里）。
    final day = monthBefore.days.first.date;

    await pumpScreen(tester);

    final row = find.byKey(Key('stats-day-${day.day}'));
    expect(row, findsOneWidget);
    await tester.tap(row);
    await settle(tester);

    // 弹层里有「当天日薪」标签与保存钮。
    expect(find.text(L10n.dayWageDialogTitle(day)), findsOneWidget);
    // 弹层里唯一的输入框就是当天日薪（GlassField 的标签不是 TextField 的
    // 子孙，widgetWithText 找不到它 —— 按序取）。
    await tester.enterText(find.byType(TextField).first, '640');
    await tester.tap(find.text(L10n.save));
    await settle(tester);

    // 库里有那一天的覆盖。
    expect((await repo.listPayrollDayWages())[dayNumber(day)], 640);

    // 界面重算：总额抬高了 320（640 替掉 320）。
    final monthAfter = computeMonthPay(
      (await repo.getActiveSchedules())!.chain,
      DateTime.now(),
      const PayrollConfig(dailyWage: 320, dailySubsidy: 10),
      await repo.listPayrollDayWages(),
    );
    expect(monthAfter.total, closeTo(monthBefore.total + 320, 0.001));
    await disposeScreen(tester);
  });

  testWidgets('发薪记录：记一笔实发，行上立刻显示；清除后回「未记」', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('stats-payroll-row')));
    await settle(tester);
    // 弹层两个框：实发金额在前、备注在后（GlassField 标签同理，按序取）。
    await tester.enterText(find.byType(TextField).at(0), '4830');
    await tester.enterText(find.byType(TextField).at(1), '银行转账');
    await tester.tap(find.text(L10n.save));
    await settle(tester);

    final now = DateTime.now();
    final records = await repo.listPayrollRecords();
    expect(records, hasLength(1));
    expect(records.single.year, now.year);
    expect(records.single.month, now.month);
    expect(records.single.actual, 4830);
    expect(records.single.note, '银行转账');

    // 再点开，走「清除记录」。
    await tester.tap(find.byKey(const Key('stats-payroll-row')));
    await settle(tester);
    await tester.tap(find.text(L10n.statsClearRecord));
    await settle(tester);
    expect(await repo.listPayrollRecords(), isEmpty);
    await disposeScreen(tester);
  });

  testWidgets('没设日薪时给一句指路，不画满屏 ¥0.00', (tester) async {
    await repo.setPayrollConfig(const PayrollConfig());
    await pumpScreen(tester);
    expect(find.byKey(const Key('stats-unset-hint')), findsOneWidget);
    expect(find.byKey(const Key('stats-payable')), findsNothing);
    await disposeScreen(tester);
  });
}
