// 薪资统计引擎 —— 纯 Dart，无 Flutter 依赖，可直接单测。
//
// 模型（用户 2026-10-23 改定，v0.12.3）：
//   · **月薪**（包月制）：一个固定数，出勤天数不改变这笔钱；
//   · **单日加项**：加班 / 双倍工资那天单独加一笔（在月薪之外）；
//   · 出不出勤由排班链决定 —— 那天有班次且不是休班，就是出勤。
//
// 月应发 = 月薪 + 加项合计，**不存库**：改了排班（调班把班调走、换了班表）或
// 改了加项，应发跟着变 —— 这份账本来就是「按表算出来的」，存一份快照只会多出
// 一个会与现算打架的数字。人手记的只有实发（`payroll_record_rows`）。
//
// **T11 判据**：出勤 0 天的月，月薪不计入（`total == 0`）—— 凭空多出一个月薪数
// 会跟用户认知对不上（没上班，HR 也不会发）。上 1 天班月薪仍全额，这才是包月制。
// 旧引擎（v0.12.2 及以前）按「日薪 × 出勤天」累加，改排班会让历史月份的应发跟着
// 变；包月制下这条自动消失，那是更对的行为。
library;

import '../core/l10n.dart';
import 'schedule_chain.dart';
import 'shift_rotation.dart';

/// 薪资设置（库里的单例行翻出来的领域形态）。
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
  });

  /// 纯日期（UTC，`dateOnly` 口径）。
  final DateTime date;

  /// 那天的班次（恒非空、且 `isRest == false` —— 休班不进这份账）。
  final ShiftClass shift;

  /// 这天的额外加项（加班 / 双倍工资那天单独加的一笔）。0 = 没加。
  final double extra;

  /// 这天有没有设过加项（列表行据此标注，不然用户看不出这笔和别的不一样）。
  final bool hasExtra;
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

  /// 按班次简称累加的出勤天数（休班不计）—— 与 `monthTallyFor` 同一条口径：
  /// 按 `shortLabel` 累加而不是按 classes 下标，跨方案的同名班次本来就该合并。
  final Map<String, int> shiftCounts;

  /// 这个月的月薪（从 [PayrollConfig.monthlyWage] 取，算 [total] 用）。
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
///
/// **出勤的判据只有一条**：`chain.shiftOn(day)` 给出非空且非休的班次。
/// 「其余时间 = 无」又没有段覆盖的天、空白表没有班次的天、休班天，一律不算 ——
/// 调班把班调走（请假）那天自动不发，把休班调成班（加班）那天自动发，都是
/// 同一条判据带出来的，不需要（也不该有）第二套规则。
DayPay? payForDay(
  ScheduleChain? chain,
  DateTime day,
  Map<int, double> dayExtras,
) {
  final shifts = chain?.shiftOn(day) ?? const [];
  // 找第一个非休班（出勤判据）
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
  );
}

/// 算 [month]（任意指到该月内的一天即可）整月的账。
MonthPay computeMonthPay(
  ScheduleChain? chain,
  DateTime month,
  PayrollConfig config,
  Map<int, double> dayExtras,
) {
  final days = DateTime(month.year, month.month + 1, 0).day;
  final pays = <DayPay>[];
  final counts = <String, int>{};
  for (var d = 1; d <= days; d++) {
    final date = DateTime(month.year, month.month, d);
    final pay = payForDay(chain, date, dayExtras);
    if (pay == null) continue;
    pays.add(pay);
    counts.update(pay.shift.shortLabel, (n) => n + 1, ifAbsent: () => 1);
  }
  return MonthPay(
    year: month.year,
    month: month.month,
    days: pays,
    shiftCounts: counts,
    monthlyWage: config.monthlyWage,
  );
}

/// 算 [year] 一整年 12 个月的账（1 月在前的升序）。
///
/// 366 次 `shiftOn` 是纯函数调用（微秒级），不必缓存；年度页与月度页各算各的，
/// 谁也不依赖谁的缓存键。
List<MonthPay> computeYearPay(
  ScheduleChain? chain,
  int year,
  PayrollConfig config,
  Map<int, double> dayExtras,
) => [
      for (var m = 1; m <= 12; m++)
        computeMonthPay(chain, DateTime(year, m, 1), config, dayExtras),
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
///
/// 文案放在这边而不是 `L10n`：金额格式化在这里，而 `l10n.dart` import 本文件
/// 会成环（`day_summary.dart` 那批文案同一条路）。
String dayPaySubtitleText(DayPay d) {
  if (!d.hasExtra) return '';
  return L10n.t(
    '加项 ${moneyText(d.extra)}',
    'Extra ${moneyText(d.extra)}',
  );
}
