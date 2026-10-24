// app/test/shift_dnd_plan_test.dart
//
// 值班自动勿扰的「排定决策」—— 纯函数 `planShiftDnd`。
//
// 为什么单独测：这段逻辑与原生插件 / DateTime.now() 缠在 reschedule 里，本机
// 没有可运行的原生目标。抽成不碰系统、不读挂钟的纯函数之后才测得到。
//
// 钉住四件事：跨午夜（end < start 的回绕表示）结束落在次日；24 小时值班
// （end ≥ 1440 的累加表示）同理；多段班次每段出开 + 关两条（segIndex 连续）；
// offset 从**今天**起算（勿扰的时刻不会落到前一天，与 planShiftAlarms 的
// 「从昨天」不同）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiftassistantpro/domain/shift_rotation.dart';
import 'package:shiftassistantpro/features/alarm/alarm_service.dart';

/// 两天一循环的小方案：偶数日「白班」（08:00–20:00）、奇数日「休班」。
///
/// 班次名写死，用例断言的是**结构**而不是文案。
ShiftSchedule _schedule({Map<int, int> overrides = const {}}) => ShiftSchedule(
      name: '测试',
      anchorDate: DateTime.utc(2026, 9, 20),
      classes: const [
        ShiftClass(
            id: 11,
            name: '白班',
            abbr: '白',
            startMinute: 8 * 60,
            endMinute: 20 * 60),
        ShiftClass(
            id: 12,
            name: '夜班',
            abbr: '夜',
            startMinute: 20 * 60,
            endMinute: 8 * 60),
        ShiftClass(id: 13, name: '休班', abbr: '休', isRest: true),
      ],
      cycle: const [[0], [2]],
      teamCount: 1,
      teamNames: const ['我'],
      teamOffsets: const [0],
      dayOverrides: overrides,
    );

void main() {
  test('基线：白班那天出开 + 关两条，offset 从今天起算', () {
    final plans = planShiftDnd(_schedule(),
        from: DateTime(2026, 9, 20, 6), days: 2);
    expect(plans, hasLength(2));
    expect(plans[0].dndOn, isTrue);
    expect(plans[0].at, DateTime(2026, 9, 20, 8));
    expect(plans[0].offset, 0, reason: 'offset 从**今天**起算');
    expect(plans[0].segIndex, 0);
    expect(plans[1].dndOn, isFalse);
    expect(plans[1].at, DateTime(2026, 9, 20, 20));
  });

  test('夜班跨午夜：结束落在次日（end < start 的回绕表示）', () {
    // 9 月 21 日本来是休班；覆盖成夜班（20:00–次日 08:00）。结束那条的 at
    // 必须是**次日** 08:00，offset 仍是开班那天的 0 —— 结束属于那一段，
    // 不跟着跑到次日去占号。
    final day = DateTime(2026, 9, 21);
    final plans = planShiftDnd(
        _schedule(overrides: {dayNumber(day): 1}),
        from: day,
        days: 1);
    expect(plans, hasLength(2));
    expect(plans[0].at, DateTime(2026, 9, 21, 20));
    expect(plans[0].offset, 0);
    expect(plans[1].at, DateTime(2026, 9, 22, 8),
        reason: '回绕表示的结束落在次日');
    expect(plans[1].offset, 0);
  });

  test('24 小时值班（end ≥ 1440 的累加表示）：结束落在次日', () {
    final schedule = ShiftSchedule(
      name: '测试',
      anchorDate: DateTime.utc(2026, 9, 20),
      classes: const [
        ShiftClass(
            id: 21,
            name: '值班',
            abbr: '值',
            startMinute: 8 * 60,
            endMinute: 32 * 60),
      ],
      cycle: const [[0]],
      teamCount: 1,
      teamNames: const ['我'],
      teamOffsets: const [0],
    );
    final plans =
        planShiftDnd(schedule, from: DateTime(2026, 9, 20, 6), days: 1);
    expect(plans, hasLength(2));
    expect(plans[0].at, DateTime(2026, 9, 20, 8));
    expect(plans[1].at, DateTime(2026, 9, 21, 8));
  });

  test('休班不排', () {
    final plans = planShiftDnd(_schedule(),
        from: DateTime(2026, 9, 21, 6), days: 1);
    expect(plans, isEmpty);
  });

  test('多段班次：每段出开 + 关两条（segIndex 连续）', () {
    final schedule = ShiftSchedule(
      name: '测试',
      anchorDate: DateTime.utc(2026, 9, 20),
      classes: const [
        ShiftClass(
            id: 31,
            name: '两段',
            abbr: '两',
            startMinute: 8 * 60,
            endMinute: 12 * 60,
            extraSegments: [ShiftSegment(14 * 60, 18 * 60)]),
      ],
      cycle: const [[0]],
      teamCount: 1,
      teamNames: const ['我'],
      teamOffsets: const [0],
    );
    final plans =
        planShiftDnd(schedule, from: DateTime(2026, 9, 20, 6), days: 1);
    expect(plans, hasLength(4));
    expect(plans.map((p) => p.at).toList(), [
      DateTime(2026, 9, 20, 8),
      DateTime(2026, 9, 20, 12),
      DateTime(2026, 9, 20, 14),
      DateTime(2026, 9, 20, 18),
    ]);
    expect(plans.map((p) => p.segIndex).toList(), [0, 0, 1, 1]);
    expect(plans.map((p) => p.dndOn).toList(), [true, false, true, false]);
  });

  test('已过的开始被过滤，未来仍有的结束照样排', () {
    // from 是中午：白班 08:00 的开始已过 → 过滤掉；20:00 的结束还在未来 → 照排。
    final plans = planShiftDnd(_schedule(),
        from: DateTime(2026, 9, 20, 12), days: 1);
    expect(plans, hasLength(1));
    expect(plans.single.dndOn, isFalse);
    expect(plans.single.at, DateTime(2026, 9, 20, 20));
  });

  test('整段都在过去时一条不出', () {
    // from 是晚上 21:00：白班（08:00–20:00）的开与关都过去了 → 空。
    final plans = planShiftDnd(_schedule(),
        from: DateTime(2026, 9, 20, 21), days: 1);
    expect(plans, isEmpty);
  });
}
