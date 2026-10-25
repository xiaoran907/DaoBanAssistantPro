// 薪资统计引擎 —— 纯 Dart，无 Flutter 依赖，可直接单测。
//
// 模型（用户 2026-10-24 改定，v0.13）：
//   · **逐月月薪**：每月一条可编辑记录（「每个月可能月薪都不一样」），不再是全局固定数；
//   · **单日加项**：加班 / 双倍工资那天单独加一笔（在月薪之外）；
//   · **多条实发**：同一个月可以记多条实发记录（月中一次、月底一次）；
//   · 出不出勤由排班链决定 —— 那天有班次且不是休班，就是出勤。
//
// 月应发 = 当月月薪 + 加项合计，**不存库**：改了排班或加项，应发跟着变。
// 人手记的只有实发（`payroll_record_rows`），可多条。
//
// **T11 判据**：出勤 0 天的月，月薪不计入（`total == 0`）—— 凭空多出一个月薪数
// 会跟用户认知对不上（没上班，HR 也不会发）。上 1 天班月薪仍全额。
library;

import '../core/l10n.dart';
import 'schedule_chain.dart';
import 'shift_rotation.dart';

/// 逐月月薪配置（库里每月一条记录的领域形态）。
///
/// 用户 2026-10-24 拍板：不想要「全局月薪」一个固定数，而是「逐月灵活填」。
class MonthlyWageConfig {
  const MonthlyWageConfig({
    required this.year,
    required this.month,
    this.wage = 0,
    this.note,
  });

  final int year;

  /// 1..12。
  final int month;

  /// 这个月的月薪（元）。0 = 没填。
  final double wage;

  /// 可选备注。
  final String? note;

  /// 0 = 用户还没配过这个月（统计页据此显示指路文案，而不是画 ¥0.00）。
  bool get isUnset => wage == 0;

  /// 唯一键：`(year, month)`。
  (int, int) get key => (year, month);

  /// 兼容旧接口：返回 [wage]（旧的 `monthlyWage` 字段已废弃）。
  double get monthlyWage => wage;
}

/// 薪资设置（库里的单例行）。
///
/// **已废弃**（v0.13）：旧的「全局月薪」配置。用 [MonthlyWageConfig] 代替。
/// 保留这个类是为了兼容旧 UI 代码（如 `stats_screen.dart`），但新的代码应直接用
/// [MonthlyWageConfig]。
@Deprecated('Use MonthlyWageConfig instead')
class PayrollConfig {
  const PayrollConfig({this.monthlyWage = 0});

  /// 月薪（元/月）。
  final double monthlyWage;

  /// 0 = 用户还没配过（统计页据此提示去设置，而不是画一张全是 ¥0.00 的卡）。
  bool get isUnset => monthlyWage == 0;
}

/// 一个出勤天的钱。
class DayPay {
  const DayPay({
    required this.date,
    required this.shift,
    required this.extra,
    required this.hasExtra,
    this.note,
  });

  /// 纯日期（UTC，`dateOnly` 口径）。
  final DateTime date;

  /// 那天的班次（恒非空、且 `isRest == false` —— 休班不进这份账）。
  final ShiftClass shift;

  /// 这天的额外加项（加班 / 双倍工资那天单独加的一笔）。0 = 没加。
  final double extra;

  /// 这天有没有设过加项（列表行据此标注，不然用户看不出这笔和别的不一样）。
  final bool hasExtra;

  /// 加项备注（用户 2026-10-25：按日出勤可备注信息）。可空。
  final String? note;
}

/// 一个月的薪资账。
class MonthPay {
  const MonthPay({
    required this.year,
    required this.month,
    required this.days,
    required this.shiftCounts,
    required this.monthlyWage,
  });

  final int year;

  /// 1..12。
  final int month;

  /// 出勤天（按日期升序）。休班 / 无排班的天不在里面。
  final List<DayPay> days;

  /// 按班次简称累加的出勤天数（休班不计）。
  final Map<String, int> shiftCounts;

  /// 这个月的月薪（从 [MonthlyWageConfig.wage] 取，算 [total] 用）。
  final double monthlyWage;

  int get workedDays => days.length;

  /// 所有出勤天的额外加项之和。
  double get extraTotal => days.fold(0, (sum, d) => sum + d.extra);

  /// 月应发 = 月薪 + 加项合计。**出勤 0 天时月薪不计入**（T11 判据）。
  double get total => days.isEmpty ? 0 : (monthlyWage + extraTotal);

  /// 有设过加项的天数（> 0 时列表里值得给一句提醒）。
  int get extraDays => days.where((d) => d.hasExtra).length;
}

/// 某天的钱；休班或那天没有任何排班返回 null（不进账）。
DayPay? payForDay(
  ScheduleChain? chain,
  DateTime day,
  Map<int, double> dayExtras, {
  Map<int, String> dayNotes = const {},
}) {
  final shifts = chain?.shiftOn(day) ?? const [];
  ShiftClass? workShift;
  for (final shift in shifts) {
    if (!shift.isRest) {
      workShift = shift;
      break;
    }
  }
  if (workShift == null) return null;
  final extraValue = dayExtras[dayNumber(day)];
  return DayPay(
    date: dateOnly(day),
    shift: workShift,
    extra: extraValue ?? 0,
    hasExtra: extraValue != null,
    note: dayNotes[dayNumber(day)],
  );
}

/// 算 [month] 整月的账。
///
/// [monthlyWage] 从 [MonthlyWageConfig] 取（该月的月薪），不再是全局固定数。
MonthPay computeMonthPay(
  ScheduleChain? chain,
  DateTime month,
  double monthlyWage,
  Map<int, double> dayExtras, {
  Map<int, String> dayNotes = const {},
}) {
  final days = DateTime(month.year, month.month + 1, 0).day;
  final pays = <DayPay>[];
  final counts = <String, int>{};
  for (var d = 1; d <= days; d++) {
    final date = DateTime(month.year, month.month, d);
    final pay = payForDay(chain, date, dayExtras, dayNotes: dayNotes);
    if (pay == null) continue;
    pays.add(pay);
    counts.update(pay.shift.shortLabel, (n) => n + 1, ifAbsent: () => 1);
  }
  return MonthPay(
    year: month.year,
    month: month.month,
    days: pays,
    shiftCounts: counts,
    monthlyWage: monthlyWage,
  );
}

/// 算 [year] 一整年 12 个月的账。
///
/// [monthlyWages] 的键是 `(year, month)`，值是该月的月薪；缺该月的配置时按 0 计。
List<MonthPay> computeYearPay(
  ScheduleChain? chain,
  int year,
  Map<(int, int), double> monthlyWages,
  Map<int, double> dayExtras, {
  Map<int, String> dayNotes = const {},
}) => [
      for (var m = 1; m <= 12; m++)
        computeMonthPay(
            chain, DateTime(year, m, 1), monthlyWages[(year, m)] ?? 0,
            dayExtras, dayNotes: dayNotes),
    ];

/// 金额：两位小数 + 千分位。`¥` 符号由界面层拼（这里只管数）。
String formatMoney(double v) {
  final negative = v < 0;
  final cents = ((v.abs() * 100).round()).toString().padLeft(3, '0');
  final whole = cents.substring(0, cents.length - 2);
  final frac = cents.substring(cents.length - 2);
  final buffered = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buffered.write(',');
    buffered.write(whole[i]);
  }
  return '${negative ? '-' : ''}$buffered.$frac';
}

/// 金额带货币符号（界面统一走这一个入口）。
String moneyText(double v) => '${L10n.currencySymbol}${formatMoney(v)}';

/// 出勤天列表行的副标题：「加项 ¥320.00」。没设过加项时返回空串。
String dayPaySubtitleText(DayPay d) {
  if (!d.hasExtra) return '';
  return L10n.t(
    '加项 ${moneyText(d.extra)}',
    'Extra ${moneyText(d.extra)}',
  );
}
