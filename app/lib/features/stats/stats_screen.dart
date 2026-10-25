import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/glass/glass.dart';
import '../../core/haptics.dart';
import '../../core/l10n.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/centered_content.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass_action_button.dart';
import '../../core/widgets/glass_dialog.dart';
import '../../core/widgets/glass_field.dart';
import '../../core/widgets/glass_input.dart';
import '../../core/widgets/glass_pickers.dart';
import '../../core/widgets/glass_pill.dart';
import '../../core/widgets/glass_pressable.dart';
import '../../core/widgets/glass_segment.dart';
import '../../core/widgets/glass_snackbar.dart';
import '../../core/widgets/section_heading.dart';
import '../../data/app_repository.dart';
import '../../domain/payroll.dart';
import '../../domain/schedule_chain.dart';

/// 统计页：日薪与补助的月度 / 年度账，以及每月的实发记录。
///
/// 钱的全部口径在 `domain/payroll.dart`（纯 Dart、可单测）：出勤 = 那天有非休
/// 班次；日薪 = 当天单独设过用那笔、否则固定日薪；补助按出勤天、全局一笔。
/// 本页只负责把数字摆出来 —— 「应发」永远现算不存库，改了排班或改了日薪，
/// 历史月份跟着变是有意的；人手记的只有实发（`payroll_record_rows`）。
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key, this.initialYearMode = false});

  /// 初次进来停在年度页（工装出年度那张图用；用户入口恒为月度）。
  final bool initialYearMode;

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  late DateTime _month; // 显示月的 1 号
  late int _year;
  late bool _yearMode;

  /// 换月 / 换年的方向：+1 往后、-1 往前（与日历页同一条规矩）。
  int _monthRoll = 1;
  int _yearRoll = 1;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _month = DateTime(n.year, n.month, 1);
    _year = n.year;
    _yearMode = widget.initialYearMode;
  }

  void _setMonth(DateTime m) {
    final next = DateTime(m.year, m.month, 1);
    if (next == _month) return;
    setState(() {
      _monthRoll = next.isAfter(_month) ? 1 : -1;
      _month = next;
      _year = next.year;
    });
  }

  void _prevMonth() => _setMonth(DateTime(_month.year, _month.month - 1, 1));
  void _nextMonth() => _setMonth(DateTime(_month.year, _month.month + 1, 1));

  void _setYear(int y) {
    if (y == _year) return;
    setState(() {
      _yearRoll = y > _year ? 1 : -1;
      _year = y;
    });
  }

  Future<void> _pickMonth() async {
    final picked = await showGlassMonthPicker(context, initialMonth: _month);
    if (picked != null && mounted) _setMonth(picked);
  }

  // ── 薪资设置（逐月月薪） ──────────────────────────────────────

  Future<void> _showWageSettings(MonthlyWageConfig config) async {
    final wageCtrl = TextEditingController(
        text: config.wage == 0 ? '' : _plain(config.wage));
    final saved = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: L10n.statsWageSettings,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GlassField(
              label: L10n.statsMonthlyWage,
              child: TextField(
                controller: wageCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^[\d.,]+$')),
                ],
                decoration: glassInputDecoration(context),
              ),
            ),
          ],
        ),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            label: L10n.cancel,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            label: L10n.save,
          ),
        ],
      ),
    );
    final wageText = wageCtrl.text;
    // 控制器**不 dispose**：弹层退场动画里 TextField 还会再读一次，提前
    // dispose 会抛「A TextEditingController was used after being disposed」
    // （schedule_editor_screen 的 _saveAsTemplate 同一条约定）。
    if (saved != true || !mounted) return;
    final wage = _parseAmount(wageText) ?? 0;
    await ref
        .read(appRepositoryProvider)
        .setMonthlyWageConfig(MonthlyWageConfig(
          year: config.year,
          month: config.month,
          wage: wage,
        ));
    Haptics.commit();
  }

  // ── 当天加项 ────────────────────────────────────────────────────

  /// 弹层的三种去向：保存（value 可为 null = 清除加项）/ 清除自定义 / 取消。
  Future<void> _showDayWageDialog(DayPay pay) async {
    final ctrl = TextEditingController(text: _plain(pay.extra));
    final hasCustom = pay.hasExtra;
    final result = await showGlassDialog<(String, double?)>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: L10n.dayExtraDialogTitle(pay.date),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayPaySubtitleText(pay),
                style: AppTokens.rowSecondary
                    .copyWith(color: AppTokens.inkMuted(context))),
            const SizedBox(height: AppTokens.spaceMd),
            GlassField(
              label: L10n.statsDayExtraField,
              child: TextField(
                controller: ctrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^[\d.,]+$')),
                ],
                decoration: glassInputDecoration(context),
              ),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            // 快捷按钮：加项档位（用户 2026-10-24 拍板 D2，2026-10-25 加 300/200/50）。
            Wrap(
              spacing: AppTokens.gapIconText,
              runSpacing: AppTokens.gapIconText,
              children: [
                for (final (label, v) in [
                  (L10n.statsExtraQuick100, '100'),
                  (L10n.statsExtraQuick300, '300'),
                  (L10n.statsExtraQuick200, '200'),
                  (L10n.statsExtraQuick50, '50'),
                ])
                  GlassActionButton(
                    variant: GlassActionVariant.secondary,
                    onPressed: () {
                      ctrl.text = v;
                      ctrl.selection =
                          TextSelection.collapsed(offset: v.length);
                    },
                    label: label,
                  ),
              ],
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Text(L10n.statsDayExtraHint,
                style: AppTokens.microText
                    .copyWith(color: AppTokens.inkMuted(context))),
          ],
        ),
        actions: [
          // 「清除自定义」只在真的单独设过时出现：没设过的天没有东西可清。
          if (hasCustom)
            GlassActionButton(
              variant: GlassActionVariant.danger,
              onPressed: () => Navigator.pop(dialogContext, ('clear', null)),
              label: L10n.statsClearExtra,
            ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () => Navigator.pop(dialogContext, ('cancel', null)),
            label: L10n.cancel,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () {
              final v = _parseAmount(ctrl.text);
              Navigator.pop(dialogContext, ('save', v));
            },
            label: L10n.save,
          ),
        ],
      ),
    );
    final text = ctrl.text;
    // 不 dispose（理由见上面 _showWageSettings）。
    if (result == null || !mounted) return;
    final (action, value) = result;
    final repo = ref.read(appRepositoryProvider);
    switch (action) {
      case 'clear':
        await repo.clearPayrollDayWage(pay.date);
        if (mounted) {
          showGlassSnack(context, L10n.dayExtraCleared(1),
              icon: Icons.restart_alt_outlined);
        }
        Haptics.commit();
      case 'save':
        if (value == null && _parseAmount(text) == null) {
          // 输入框留空保存 = 回退到固定日薪（与「清除自定义」同一语义）。
          await repo.clearPayrollDayWage(pay.date);
          if (mounted) {
            showGlassSnack(context, L10n.dayExtraCleared(1),
                icon: Icons.restart_alt_outlined);
          }
        } else if (value != null) {
          await repo.setPayrollDayWage(pay.date, value);
          if (mounted) {
            showGlassSnack(context, L10n.extraSet,
                icon: Icons.check_circle_outlined);
          }
        } else if (mounted) {
          showGlassSnack(context, L10n.invalidAmount,
              icon: Icons.error_outline);
        }
        Haptics.commit();
    }
  }

  // ── 发薪记录 ────────────────────────────────────────────────────

  Future<void> _showRecordDialog(
    int year,
    int month,
    PayrollRecordRow? existing,
  ) async {
    final amountCtrl = TextEditingController(
        text: existing?.actual == null ? '' : _plain(existing!.actual!));
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    final result = await showGlassDialog<(String, double?, String)>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title:
            '${L10n.statsPayrollSection} · ${L10n.yearMonth(DateTime(year, month, 1))}',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GlassField(
              label: L10n.statsActualAmount,
              child: TextField(
                controller: amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^[\d.,]+$')),
                ],
                decoration: glassInputDecoration(context),
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            GlassField(
              label: L10n.statsActualNote,
              child: TextField(
                controller: noteCtrl,
                decoration: glassInputDecoration(context),
              ),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            GlassActionButton(
              variant: GlassActionVariant.danger,
              onPressed: () =>
                  Navigator.pop(dialogContext, ('clear', null, '')),
              label: L10n.statsClearRecord,
            ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () =>
                Navigator.pop(dialogContext, ('cancel', null, '')),
            label: L10n.cancel,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () {
              final v = _parseAmount(amountCtrl.text);
              Navigator.pop(dialogContext, ('save', v, noteCtrl.text.trim()));
            },
            label: L10n.save,
          ),
        ],
      ),
    );
    // 不 dispose（理由见上面 _showWageSettings）。
    if (result == null || !mounted) return;
    final (action, actual, noteFromDialog) = result;
    final note = noteFromDialog.isNotEmpty ? noteFromDialog : null;
    final repo = ref.read(appRepositoryProvider);
    final monthLabel = L10n.yearMonth(DateTime(year, month, 1));
    switch (action) {
      case 'clear':
        await repo.deletePayrollRecord(year, month, 0);
        if (mounted) {
          showGlassSnack(context, L10n.recordCleared(monthLabel),
              icon: Icons.delete_outline);
        }
        Haptics.commit();
      case 'save':
        if (actual == null && (note == null || note.isEmpty)) {
          // 两样都空 = 没有可记的东西：当成清除，不留在库里一行空记录。
          await repo.deletePayrollRecord(year, month, 0);
          if (mounted) {
            showGlassSnack(context, L10n.recordCleared(monthLabel),
                icon: Icons.delete_outline);
          }
        } else {
          await repo.savePayrollRecord(
              year: year, month: month, seq: 0,
              actual: actual, note: note);
          if (mounted) {
            showGlassSnack(context, L10n.recordSaved(monthLabel),
                icon: Icons.check_circle_outlined);
          }
        }
        Haptics.commit();
    }
  }

  // ── 金额输入 / 展示的 helpers ──────────────────────────────────

  /// 编辑框里的「普通数字串」（formatMoney 的千分位逗号剥掉）。
  static String _plain(double v) => formatMoney(v).replaceAll(',', '');

  static double? _parseAmount(String raw) {
    final cleaned = raw.trim().replaceAll(',', '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  // ── 月份滚动动画（与日历页同一套：位移 6% + 淡入淡出，方向跟翻页方向） ──

  Widget _slide({required Object tag, required Widget child}) {
    final roll = _yearMode ? _yearRoll : _monthRoll;
    return AnimatedSwitcher(
      duration: AppTokens.durMed,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: (child, animation) {
        final isCurrent = child.key == ValueKey(tag);
        final dir = isCurrent ? roll : -roll;
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0.06 * dir, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(tag), child: child),
    );
  }

  Widget _circleIcon(BuildContext context, IconData icon, String tooltip,
      VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      // 与日历页顶栏同一颗圆钮：玻璃的 Q 弹缩放做按压反馈，不套 InkWell
      //（水波纹只该出现在弹层的 ListTile 里）。
      child: GlassPressable(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        Colors.white.withValues(alpha: 0.10),
                        Colors.white.withValues(alpha: 0.04),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.85),
                        Colors.white.withValues(alpha: 0.55),
                      ],
              ),
              border: Border.all(color: AppTokens.glassBorder(isDark)),
            ),
            child: AppIcon(
              icon,
              size: AppTokens.iconLg,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chain = ref.watch(activeScheduleProvider).valueOrNull?.chain;
    final monthlyWages =
        ref.watch(monthlyWageConfigsProvider).valueOrNull ??
            const <(int, int), double>{};
    final config = MonthlyWageConfig(
      year: _month.year,
      month: _month.month,
      wage: monthlyWages[(_month.year, _month.month)] ?? 0,
    );
    final dayWages =
        ref.watch(payrollDayWagesProvider).valueOrNull ?? const <int, double>{};
    final records = ref.watch(payrollRecordsProvider).valueOrNull ??
        const <PayrollRecordRow>[];

    PayrollRecordRow? recordFor(int year, int month) {
      for (final r in records) {
        if (r.year == year && r.month == month) return r;
      }
      return null;
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CenteredContent(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            physics: const BouncingScrollPhysics(),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(L10n.navSalary, style: AppTokens.pageTitle),
                  ),
                  const SizedBox(width: AppTokens.spaceSm),
                  GlassPill(
                    onTap: () => _showWageSettings(config),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon(
                          Icons.payments_outlined,
                          size: AppTokens.iconMd,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        const SizedBox(width: AppTokens.gapHair),
                        Text(
                          L10n.statsWageSettings,
                          maxLines: 1,
                          style: AppTokens.labelSecondary.copyWith(
                              color: Theme.of(context).colorScheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GlassSegment(
                count: 2,
                selectedIndex: _yearMode ? 1 : 0,
                onSelected: (i) {
                  if ((i == 1) == _yearMode) return;
                  Haptics.select();
                  setState(() => _yearMode = i == 1);
                },
                itemBuilder: (i, selected) => Text(
                  [L10n.statsModeMonth, L10n.statsModeYear][i],
                  // 基线 13px：未选中 w500、选中 w700（与「我的」页那几个分段器同一套）。
                  style: AppTokens.labelSecondary.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_yearMode)
                _slide(
                  tag: 'year-$_year',
                  child: _buildYear(
                    context,
                    chain: chain,
                    config: PayrollConfig(monthlyWage: config.wage),
                    dayWages: dayWages,
                    recordFor: recordFor,
                  ),
                )
              else
                _slide(
                  tag: 'month-${_month.year}-${_month.month}',
                  child: _buildMonth(
                    context,
                    chain: chain,
                    config: PayrollConfig(monthlyWage: config.wage),
                    dayWages: dayWages,
                    record: recordFor(_month.year, _month.month),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 月度 ────────────────────────────────────────────────────────

  Widget _buildMonth(
    BuildContext context, {
    required ScheduleChain? chain,
    required PayrollConfig config,
    required Map<int, double> dayWages,
    required PayrollRecordRow? record,
  }) {
    final pay = computeMonthPay(chain, _month, config.monthlyWage, dayWages);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _circleIcon(context, Icons.chevron_left_outlined, L10n.prevMonth,
                _prevMonth),
            const SizedBox(width: AppTokens.gapIconText),
            Expanded(
              child: GlassPill(
                onTap: _pickMonth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    L10n.yearMonth(_month),
                    maxLines: 1,
                    style: AppTokens.titleStrong,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppTokens.gapIconText),
            _circleIcon(context, Icons.chevron_right_outlined, L10n.nextMonth,
                _nextMonth),
          ],
        ),
        const SizedBox(height: AppTokens.spaceMd),
        _summaryCard(context, pay, config),
        const SizedBox(height: AppTokens.spaceMd),
        _payrollCard(context, record),
        const SizedBox(height: AppTokens.spaceMd),
        SectionHeading(L10n.statsDayListTitle),
        const SizedBox(height: AppTokens.spaceSm),
        _dayListCard(context, pay),
      ],
    );
  }

  Widget _summaryCard(
      BuildContext context, MonthPay pay, PayrollConfig config) {
    final muted = AppTokens.inkMuted(context);
    final primary = Theme.of(context).colorScheme.primary;
    return GlassTile(
      translucentFill: false,
      padding: const EdgeInsets.all(16),
      child: config.isUnset
          ? Text(
              L10n.statsWageUnset,
              key: const Key('stats-unset-hint'),
              style: AppTokens.rowSecondary.copyWith(color: muted),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(L10n.statsPayable,
                    style: AppTokens.labelSecondary.copyWith(color: muted)),
                const SizedBox(height: AppTokens.gapHair),
                Text(
                  moneyText(pay.total),
                  key: const Key('stats-payable'),
                  // 金额跟着主色走：读账的人第一眼落在它上面。
                  style: AppTokens.bigNumber.copyWith(color: primary),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                        child: _statCell(
                            context, L10n.workedDaysCount(pay.workedDays))),
                    Expanded(
                        child: _statCell(context, L10n.statsExtraTotal,
                            moneyText(pay.extraTotal))),
                    Expanded(
                        child: _statCell(context, L10n.statsMonthlyWage,
                            moneyText(pay.monthlyWage))),
                  ],
                ),
                if (pay.shiftCounts.isNotEmpty) ...[
                  const SizedBox(height: AppTokens.spaceMd),
                  const Divider(height: 1),
                  const SizedBox(height: AppTokens.spaceSm),
                  Text(
                    [
                      L10n.statsByShift,
                      for (final e in pay.shiftCounts.entries)
                        '${e.key}${e.value}',
                    ].join(' · '),
                    key: const Key('stats-by-shift'),
                    style: AppTokens.microText.copyWith(color: muted),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _statCell(BuildContext context, String label, [String? value]) {
    final muted = AppTokens.inkMuted(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            maxLines: 2,
            style: AppTokens.microText.copyWith(color: muted)),
        if (value != null)
          // FittedBox 兜底：五位数的大账缩、不省略（设计 §2 第 2 档）。
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: AppTokens.rowPrimary),
          ),
      ],
    );
  }

  Widget _payrollCard(BuildContext context, PayrollRecordRow? record) {
    final note = record?.note;
    final subtitle = record == null
        ? L10n.statsPayrollEmpty
        : [
            if (record.actual != null)
              '${L10n.statsActualPaid} ${moneyText(record.actual!)}',
            if (note != null && note.isNotEmpty) note,
          ].join(' · ');
    return GlassTile(
      translucentFill: false,
      padding: EdgeInsets.zero,
      child: GlassPressable(
        child: ListTile(
          key: const Key('stats-payroll-row'),
          leading: const Icon(Icons.savings_outlined),
          title: Text(L10n.statsPayrollSection),
          subtitle: Text(subtitle, maxLines: 2),
          trailing: const Icon(Icons.chevron_right_outlined),
          onTap: () => _showRecordDialog(_month.year, _month.month, record),
        ),
      ),
    );
  }

  Widget _dayListCard(BuildContext context, MonthPay pay) {
    final muted = AppTokens.inkMuted(context);
    if (pay.days.isEmpty) {
      return GlassTile(
        translucentFill: false,
        padding: const EdgeInsets.all(16),
        child: EmptyState(L10n.statsMonthEmpty),
      );
    }
    return GlassTile(
      translucentFill: false,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < pay.days.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _dayRow(context, pay.days[i], muted),
          ],
        ],
      ),
    );
  }

  Widget _dayRow(BuildContext context, DayPay pay, Color muted) {
    return GlassPressable(
      child: ListTile(
        key: Key('stats-day-${pay.date.day}'),
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: Color(pay.shift.color),
            shape: BoxShape.circle,
          ),
        ),
        title: Text(
          L10n.monthDay(pay.date),
          maxLines: 1,
          style: AppTokens.rowPrimary,
        ),
        // 副标题两行封顶、不省略（设计 §6.3）：班次名 + 两笔钱在窄窗下折得下。
        subtitle: Text(
          [
            pay.shift.name,
            dayPaySubtitleText(pay),
            if (pay.hasExtra) L10n.statsExtraBadge,
          ].join(' · '),
          maxLines: 2,
          style: AppTokens.rowSecondary.copyWith(color: muted),
        ),
        trailing: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            moneyText(pay.extra),
            maxLines: 1,
            style: AppTokens.labelStrong,
          ),
        ),
        onTap: () => _showDayWageDialog(pay),
      ),
    );
  }

  // ── 年度 ────────────────────────────────────────────────────────

  Widget _buildYear(
    BuildContext context, {
    required ScheduleChain? chain,
    required PayrollConfig config,
    required Map<int, double> dayWages,
    required PayrollRecordRow? Function(int year, int month) recordFor,
  }) {
    final muted = AppTokens.inkMuted(context);
    // 未设日薪时不白算 12 个月：年度表整个换成一句提示。
    final monthlyWages = {
      for (var m = 1; m <= 12; m++) (_year, m): config.monthlyWage,
    };
    final months = config.isUnset
        ? null
        : computeYearPay(chain, _year, monthlyWages, dayWages);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _circleIcon(context, Icons.chevron_left_outlined, L10n.prevMonth,
                () => _setYear(_year - 1)),
            const SizedBox(width: AppTokens.gapIconText),
            Expanded(
              child: GlassPill(
                // 年份没有别的跳转入口（点它没意义），不响应点击。
                child: Text('$_year',
                    maxLines: 1, style: AppTokens.titleStrong),
              ),
            ),
            const SizedBox(width: AppTokens.gapIconText),
            _circleIcon(context, Icons.chevron_right_outlined, L10n.nextMonth,
                () => _setYear(_year + 1)),
          ],
        ),
        const SizedBox(height: AppTokens.spaceMd),
        GlassTile(
          translucentFill: false,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: months == null
              ? Text(L10n.statsWageUnset,
                  style: AppTokens.rowSecondary.copyWith(color: muted))
              : Column(
                  children: [
                    _yearRow(
                      context,
                      label: L10n.statsColWorked,
                      worked: '',
                      payable: L10n.statsColPayable,
                      paid: L10n.statsColPaid,
                      isHeader: true,
                    ),
                    const Divider(height: 1),
                    for (var m = 1; m <= 12; m++)
                      _yearRow(
                        context,
                        label: L10n.monthShort(m),
                        worked: '${months[m - 1].workedDays}',
                        payable: moneyText(months[m - 1].total),
                        paid: _paidCellText(recordFor(_year, m)),
                      ),
                    const Divider(height: 1),
                    _yearRow(
                      context,
                      label: L10n.statsYearTotal,
                      worked:
                          '${months.fold<int>(0, (s, m) => s + m.workedDays)}',
                      payable: moneyText(
                          months.fold<double>(0, (s, m) => s + m.total)),
                      paid: moneyText(_yearPaidTotal(_year, recordFor)),
                      isTotal: true,
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  String _paidCellText(PayrollRecordRow? record) {
    final actual = record?.actual;
    if (actual == null) return L10n.statsNotRecorded;
    return moneyText(actual);
  }

  double _yearPaidTotal(
      int year, PayrollRecordRow? Function(int year, int month) recordFor) {
    var total = 0.0;
    for (var m = 1; m <= 12; m++) {
      final a = recordFor(year, m)?.actual;
      if (a != null) total += a;
    }
    return total;
  }

  /// 年度表的一行：月份 / 出勤 / 应发 / 实发。数字列表，不是图表（全局偏好）。
  Widget _yearRow(
    BuildContext context, {
    required String label,
    required String worked,
    required String payable,
    required String paid,
    bool isHeader = false,
    bool isTotal = false,
  }) {
    final muted = AppTokens.inkMuted(context);
    final style = isHeader || isTotal
        ? AppTokens.labelSecondary.copyWith(
            color: isHeader ? muted : Theme.of(context).colorScheme.onSurface)
        : AppTokens.rowSecondary.copyWith(color: muted);
    final valueStyle = isHeader
        ? AppTokens.labelSecondary.copyWith(color: muted)
        : isTotal
            ? AppTokens.labelStrong
            : AppTokens.rowSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(label, maxLines: 1, style: style),
            ),
          ),
          Expanded(
            flex: 1,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Text(worked, maxLines: 1, style: valueStyle),
            ),
          ),
          Expanded(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(payable, maxLines: 1, style: valueStyle),
            ),
          ),
          Expanded(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(paid, maxLines: 1, style: valueStyle),
            ),
          ),
        ],
      ),
    );
  }
}
