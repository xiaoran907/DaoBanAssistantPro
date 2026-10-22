// app/test/payroll_engine_test.dart
//
// 薪资引擎（domain/payroll.dart）的口径：
//  ① 出勤的判据只有一条 —— 那天有非休班次；调班把班调走 → 不计钱，
//     把休班调成班 → 计钱，同一条判据带出来；
//  ② 日薪 = 当天单独设过用那笔，否则固定日薪；
//  ③ 补助按出勤天、全局一笔，休班 / 无排班的天一分没有；
//  ④ 跨时段（多套班表按日期衔接）的月份逐天问链，不认「当前方案」。
//
// 默认方案（`defaultSchedule()`）是四班两倒：锚点 **2025-01-06** 白班，
// 周期 = 白班(计) → 上夜班(计) → 下夜班(不计，isRest) → 大休(不计)。
// 2025-01：白 8 + 上夜 8 = 出勤 16 天。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/core/l10n.dart';
import 'package:shiftassistantpro/domain/payroll.dart';
import 'package:shiftassistantpro/domain/schedule_chain.dart';
import 'package:shiftassistantpro/domain/shift_rotation.dart';

void main() {
  setUp(() {
    // 金额拼接文案（dayPaySubtitleText / shortLabel）跟语言走，钉住中文。
    L10n.locale = 'zh';
  });

  /// 四班两倒（锚点 2025-01-06 白班）。
  ShiftSchedule fourShift() => defaultSchedule();

  group('payForDay', () {
    test('白班计钱、下夜班 / 大休与无排班的天不计', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(dailyWage: 320, dailySubsidy: 10);

      // 2025-01-06 白班（锚点当天）、2025-01-07 上夜班。
      final pay = payForDay(chain, DateTime.utc(2025, 1, 6), config, const {});
      expect(pay, isNotNull);
      expect(pay!.wage, 320);
      expect(pay.subsidy, 10);
      expect(pay.total, 330);
      expect(pay.customWage, isFalse);
      expect(pay.shift.name, '白班');
      expect(payForDay(chain, DateTime.utc(2025, 1, 7), config, const {}),
          isNotNull);

      // 下夜班（1/8）与大休（1/9）都标着 isRest。
      expect(payForDay(chain, DateTime.utc(2025, 1, 8), config, const {}),
          isNull);
      expect(payForDay(chain, DateTime.utc(2025, 1, 9), config, const {}),
          isNull);
    });

    test('「其余时间 = 无」且没有段覆盖的天：无班次 → 不计钱', () {
      // 没有任何方案兜底的空链。
      const chain = ScheduleChain();
      const config = PayrollConfig(dailyWage: 320);
      expect(payForDay(chain, DateTime.utc(2025, 1, 6), config, const {}),
          isNull);
    });

    test('单独设过的天用那笔钱，并带 customWage 标记', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(dailyWage: 320, dailySubsidy: 10);
      final wages = {dayNumber(DateTime.utc(2025, 1, 6)): 640.0};

      final pay = payForDay(chain, DateTime.utc(2025, 1, 6), config, wages);
      expect(pay!.wage, 640);
      expect(pay.customWage, isTrue);
      // 补助照发，不跟着日薪覆盖走。
      expect(pay.subsidy, 10);
    });

    test('休班天即使设了钱也不发（出勤判据说了算）', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(dailyWage: 320);
      final wages = {dayNumber(DateTime.utc(2025, 1, 9)): 500.0};
      expect(payForDay(chain, DateTime.utc(2025, 1, 9), config, wages), isNull);
    });
  });

  group('computeMonthPay', () {
    test('整月：出勤天数、两笔合计与按班次累加', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(dailyWage: 320, dailySubsidy: 10);
      final month =
          computeMonthPay(chain, DateTime.utc(2025, 1, 15), config, const {});

      // 2025-01：白班 8、上夜班 8、下夜班 7（不计）、大休 8（不计）。
      expect(month.workedDays, 16);
      expect(month.wageTotal, closeTo(16 * 320, 0.001));
      expect(month.subsidyTotal, closeTo(16 * 10, 0.001));
      expect(month.total, closeTo(16 * 330, 0.001));
      expect(month.shiftCounts['白'], 8);
      expect(month.shiftCounts['夜'], 8);
      // 下夜班与大休都不进账。
      expect(month.shiftCounts.containsKey('下'), isFalse);
      expect(month.shiftCounts.containsKey('休'), isFalse);
      // 天列表升序。
      expect(month.days.first.date.day, 2);
      expect(month.days.last.date.day, 31);
    });

    test('跨时段的一个月：上半月 A 套、下半月 B 套，逐天问链', () {
      // A：锚点 2026-01-01 白班，管到 1/15。
      final a = ShiftSchedule(
        name: 'A',
        anchorDate: DateTime.utc(2026, 1, 1),
        classes: const [
          ShiftClass(name: '白班', abbr: '白', isRest: false),
          ShiftClass(name: '大休', abbr: '休', isRest: true),
        ],
        cycle: const [0, 1],
        teamCount: 1,
        ourTeamIndex: 0,
        teamNames: ['我们'],
      );
      // B：锚点 2026-01-01 白班（错开 1 天 = 1/1 休、1/2 班），从 1/16 起。
      final b = ShiftSchedule(
        name: 'B',
        anchorDate: DateTime.utc(2026, 1, 1),
        classes: const [
          ShiftClass(name: '夜班', abbr: '夜', isRest: false),
          ShiftClass(name: '大休', abbr: '休', isRest: true),
        ],
        cycle: const [0, 1],
        teamCount: 1,
        ourTeamIndex: 0,
        teamNames: ['我们'],
      );
      final chain = ScheduleChain(
        spans: [
          ScheduleSpan(
            scheduleId: 1,
            schedule: a,
            from: DateTime.utc(2026, 1, 1),
            to: DateTime.utc(2026, 1, 15),
          ),
          ScheduleSpan(
            scheduleId: 2,
            schedule: b,
            from: DateTime.utc(2026, 1, 16),
          ),
        ],
      );
      const config = PayrollConfig(dailyWage: 100, dailySubsidy: 0);
      final month =
          computeMonthPay(chain, DateTime.utc(2026, 1, 10), config, const {});

      // 1/1..1/15：白休轮转 = 白 8 天（1,3,5,7,9,11,13,15）；
      // 1/16..1/31：从 1/16 起按 B（1/16 休、1/17 班…）= 夜 8 天。
      expect(month.workedDays, 16);
      expect(month.wageTotal, closeTo(16 * 100, 0.001));
      // 两套的「休」合并口径：计数里不该冒出第三个键。
      expect(month.shiftCounts['白'], 8);
      expect(month.shiftCounts['夜'], 8);
      expect(month.shiftCounts.length, 2);
    });

    test('自定义日薪落在哪个天就只影响哪天', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(dailyWage: 320, dailySubsidy: 10);
      final wages = {dayNumber(DateTime.utc(2025, 1, 6)): 960.0};
      final month =
          computeMonthPay(chain, DateTime.utc(2025, 1, 15), config, wages);

      // 16 天出勤：15 天 × 320 + 1 天 × 960。
      expect(month.wageTotal, closeTo(15 * 320 + 960, 0.001));
      expect(month.customWageDays, 1);
    });
  });

  group('computeYearPay', () {
    test('12 个月按 1 月在前的升序，出勤各自独立', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(dailyWage: 320);
      final year = computeYearPay(chain, 2025, config, const {});

      expect(year.length, 12);
      expect(year[0].month, 1);
      expect(year[11].month, 12);
      // 2025-01 出勤 16 天；2025-02（28 天，2/1 恰好是下夜班）出勤 14 天。
      expect(year[0].workedDays, 16);
      expect(year[1].workedDays, 14);
      // 每个月都是独立的 MonthPay。
      expect(year[0].total, closeTo(16 * 320, 0.001));
    });
  });

  group('formatMoney / moneyText', () {
    test('两位小数 + 千分位，负数带符号', () {
      expect(formatMoney(0), '0.00');
      expect(formatMoney(5), '5.00');
      expect(formatMoney(320.5), '320.50');
      expect(formatMoney(1234567.89), '1,234,567.89');
      expect(formatMoney(-12.3), '-12.30');
    });

    test('moneyText 带 ¥ 符号（两种语言同币种）', () {
      expect(moneyText(320), '¥320.00');
      L10n.locale = 'en';
      expect(moneyText(320), '¥320.00');
      L10n.locale = 'zh';
    });

    test('浮点累加不露尾巴（0.1+0.2 类）', () {
      expect(formatMoney(0.1 + 0.2), '0.30');
      expect(formatMoney(23 * 320.0), '7,360.00');
    });
  });

  test('dayPaySubtitleText 把两笔钱拼进文案', () {
    final chain = ScheduleChain(fallback: fourShift());
    final pay = payForDay(chain, DateTime.utc(2025, 1, 6),
        const PayrollConfig(dailyWage: 320, dailySubsidy: 10), const {});
    expect(
      dayPaySubtitleText(pay!),
      '日薪 ¥320.00 ＋ 补助 ¥10.00',
    );
  });
}
