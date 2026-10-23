// app/test/payroll_engine_test.dart
//
// 薪资引擎（domain/payroll.dart）的口径（v0.12.3 包月制）：
//  ① 出勤的判据只有一条 —— 那天有非休班次；调班把班调走 → 不计钱，
//     把休班调成班 → 计钱，同一条判据带出来；
//  ② 月薪是月度常量：出勤 ≥ 1 天全额计入，出勤 0 天一分不计（T11 判据）；
//  ③ 单日加项在月薪之外单独加一笔（加班 / 双倍工资那天），不按天数摊；
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
    test('白班计入账、下夜班 / 大休与无排班的天不进账', () {
      final chain = ScheduleChain(fallback: fourShift());

      // 2025-01-06 白班（锚点当天）、2025-01-07 上夜班。
      final pay = payForDay(chain, DateTime.utc(2025, 1, 6), const {});
      expect(pay, isNotNull);
      expect(pay!.extra, 0);
      expect(pay.hasExtra, isFalse);
      expect(pay.shift.name, '白班');
      expect(payForDay(chain, DateTime.utc(2025, 1, 7), const {}), isNotNull);

      // 下夜班（1/8）与大休（1/9）都标着 isRest。
      expect(payForDay(chain, DateTime.utc(2025, 1, 8), const {}), isNull);
      expect(payForDay(chain, DateTime.utc(2025, 1, 9), const {}), isNull);
    });

    test('「其余时间 = 无」且没有段覆盖的天：无班次 → 不进账', () {
      // 没有任何方案兜底的空链。
      const chain = ScheduleChain();
      expect(payForDay(chain, DateTime.utc(2025, 1, 6), const {}), isNull);
    });

    test('设过加项的天带 extra + hasExtra 标记', () {
      final chain = ScheduleChain(fallback: fourShift());
      final extras = {dayNumber(DateTime.utc(2025, 1, 6)): 640.0};

      final pay = payForDay(chain, DateTime.utc(2025, 1, 6), extras);
      expect(pay!.extra, 640);
      expect(pay.hasExtra, isTrue);
    });

    test('休班天即使设了加项也不发（出勤判据说了算）', () {
      final chain = ScheduleChain(fallback: fourShift());
      final extras = {dayNumber(DateTime.utc(2025, 1, 9)): 500.0};
      expect(payForDay(chain, DateTime.utc(2025, 1, 9), extras), isNull);
    });
  });

  group('computeMonthPay', () {
    test('整月：出勤天数、月薪全额计入、按班次累加（无加项）', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(monthlyWage: 8000);
      final month =
          computeMonthPay(chain, DateTime.utc(2025, 1, 15), config.monthlyWage, const {});

      // 2025-01：白班 8、上夜班 8、下夜班 7（不计）、大休 8（不计）。
      expect(month.workedDays, 16);
      expect(month.monthlyWage, 8000);
      expect(month.extraTotal, 0);
      // 出勤 ≥ 1 天 → 月薪全额计入，加项 0。
      expect(month.total, closeTo(8000, 0.001));
      expect(month.shiftCounts['白'], 8);
      expect(month.shiftCounts['夜'], 8);
      // 下夜班与大休都不进账。
      expect(month.shiftCounts.containsKey('下'), isFalse);
      expect(month.shiftCounts.containsKey('休'), isFalse);
      // 天列表升序。
      expect(month.days.first.date.day, 2);
      expect(month.days.last.date.day, 31);
      // 没有设过加项。
      expect(month.extraDays, 0);
    });

    test('T11 判据：出勤 0 天的月，月薪不计入', () {
      // 空链：任何一天都没有班次 → 出勤 0 天。
      const chain = ScheduleChain();
      const config = PayrollConfig(monthlyWage: 8000);
      final month =
          computeMonthPay(chain, DateTime.utc(2025, 1, 15), config.monthlyWage, const {});

      expect(month.workedDays, 0);
      expect(month.days, isEmpty);
      // 出勤 0 天 → 月薪不计入，total == 0。
      expect(month.total, 0);
      expect(month.extraTotal, 0);
    });

    test('出勤 1 天：月薪仍全额计入', () {
      // 用一个正常方案，但用 ScheduleSpan 只覆盖 1/6 这一天 ——
      // 其余天没有段覆盖 = 无排班 = 不计出勤。
      final chain = ScheduleChain(spans: [
        ScheduleSpan(
          scheduleId: 1,
          schedule: fourShift(),
          from: DateTime.utc(2025, 1, 6),
          to: DateTime.utc(2025, 1, 6),
        ),
      ]);
      const config = PayrollConfig(monthlyWage: 8000);
      final month =
          computeMonthPay(chain, DateTime.utc(2025, 1, 15), config.monthlyWage, const {});

      expect(month.workedDays, 1);
      expect(month.total, closeTo(8000, 0.001));
    });

    test('加项计入 extraTotal 并进 total', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(monthlyWage: 8000);
      final extras = {
        dayNumber(DateTime.utc(2025, 1, 6)): 640.0,
        dayNumber(DateTime.utc(2025, 1, 10)): 320.0,
      };
      final month = computeMonthPay(chain, DateTime.utc(2025, 1, 15), config.monthlyWage, extras);

      expect(month.extraTotal, closeTo(640 + 320, 0.001));
      expect(month.extraDays, 2);
      // total = 月薪 + 加项。
      expect(month.total, closeTo(8000 + 640 + 320, 0.001));
    });

    test('加项落在休班天不算（出勤判据说了算）', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(monthlyWage: 8000);
      // 1/9 是大休（isRest）。
      final extras = {dayNumber(DateTime.utc(2025, 1, 9)): 500.0};
      final month = computeMonthPay(chain, DateTime.utc(2025, 1, 15), config.monthlyWage, extras);

      expect(month.extraTotal, 0);
      expect(month.extraDays, 0);
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
        cycle: const [[0], [1]],
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
        cycle: const [[0], [1]],
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
      const config = PayrollConfig(monthlyWage: 8000);
      final month =
          computeMonthPay(chain, DateTime.utc(2026, 1, 10), config.monthlyWage, const {});

      // 1/1..1/15：白休轮转 = 白 8 天（1,3,5,7,9,11,13,15）；
      // 1/16..1/31：从 1/16 起按 B（1/16 休、1/17 班…）= 夜 8 天。
      expect(month.workedDays, 16);
      expect(month.total, closeTo(8000, 0.001));
      // 两套的「休」合并口径：计数里不该冒出第三个键。
      expect(month.shiftCounts['白'], 8);
      expect(month.shiftCounts['夜'], 8);
      expect(month.shiftCounts.length, 2);
    });
  });

  group('computeYearPay', () {
    test('12 个月按 1 月在前的升序，出勤各自独立', () {
      final chain = ScheduleChain(fallback: fourShift());
      const config = PayrollConfig(monthlyWage: 8000);
      final monthlyWages = {
        for (var m = 1; m <= 12; m++) (2025, m): config.monthlyWage,
      };
      final year = computeYearPay(chain, 2025, monthlyWages, const {});

      expect(year.length, 12);
      expect(year[0].month, 1);
      expect(year[11].month, 12);
      // 2025-01 出勤 16 天；2025-02（28 天，2/1 恰好是下夜班）出勤 14 天。
      expect(year[0].workedDays, 16);
      expect(year[1].workedDays, 14);
      // 每个月出勤 ≥ 1 天 → 月薪全额。
      expect(year[0].total, closeTo(8000, 0.001));
    });

    test('某个月出勤 0 天时该月 total == 0，不影响其他月', () {
      // 构造一条链：只有 2025-02 有班，1 月与 3 月全是休。
      final febOnly = ShiftSchedule(
        name: '只有二月',
        anchorDate: DateTime.utc(2025, 2, 1),
        classes: const [
          ShiftClass(name: '白班', abbr: '白', isRest: false),
          ShiftClass(name: '大休', abbr: '休', isRest: true),
        ],
        cycle: const [[0], [1]],
        teamCount: 1,
        ourTeamIndex: 0,
        teamNames: ['我们'],
      );
      // 用段把 2 月单独包起来，其余时间无排班。
      final chain = ScheduleChain(spans: [
        ScheduleSpan(
          scheduleId: 1,
          schedule: febOnly,
          from: DateTime.utc(2025, 2, 1),
          to: DateTime.utc(2025, 2, 28),
        ),
      ]);
      const config = PayrollConfig(monthlyWage: 8000);
      final monthlyWages = {
        for (var m = 1; m <= 12; m++) (2025, m): config.monthlyWage,
      };
      final year = computeYearPay(chain, 2025, monthlyWages, const {});

      // 1 月出勤 0 天 → total == 0（T11）。
      expect(year[0].workedDays, 0);
      expect(year[0].total, 0);
      // 2 月有班 → 月薪全额。
      expect(year[1].workedDays, greaterThan(0));
      expect(year[1].total, closeTo(8000, 0.001));
      // 3 月出勤 0 天 → total == 0。
      expect(year[2].workedDays, 0);
      expect(year[2].total, 0);
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

  group('dayPaySubtitleText', () {
    test('有加项：拼成「加项 ¥640.00」', () {
      final chain = ScheduleChain(fallback: fourShift());
      final extras = {dayNumber(DateTime.utc(2025, 1, 6)): 640.0};
      final pay = payForDay(chain, DateTime.utc(2025, 1, 6), extras);
      expect(dayPaySubtitleText(pay!), '加项 ¥640.00');
    });

    test('没加项：返回空串（不画满屏 ¥0.00）', () {
      final chain = ScheduleChain(fallback: fourShift());
      final pay = payForDay(chain, DateTime.utc(2025, 1, 6), const {});
      expect(dayPaySubtitleText(pay!), '');
    });

    test('英文语种', () {
      L10n.locale = 'en';
      final chain = ScheduleChain(fallback: fourShift());
      final extras = {dayNumber(DateTime.utc(2025, 1, 6)): 640.0};
      final pay = payForDay(chain, DateTime.utc(2025, 1, 6), extras);
      expect(dayPaySubtitleText(pay!), 'Extra ¥640.00');
      L10n.locale = 'zh';
    });
  });
}
