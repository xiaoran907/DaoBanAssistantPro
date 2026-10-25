import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_tokens.dart';
import '../../core/frame_notifier.dart';
import '../../core/haptics.dart';
import '../../core/glass/glass.dart';
import '../../core/glass/liquid_lens.dart';
import '../../core/layout.dart';
import '../../core/l10n.dart';
import '../../core/theme/animated_background.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass_dialog.dart';
import '../../core/widgets/glass_loading.dart';
import '../../core/widgets/glass_pickers.dart';
import '../../core/widgets/glass_pill.dart';
import '../../core/widgets/glass_pressable.dart';
import '../../core/widgets/glass_sheet_header.dart';
import '../../core/widgets/glass_snackbar.dart';
import '../../data/app_repository.dart';
import '../../domain/lunar_info.dart';
import '../../domain/day_summary.dart';
import '../../domain/schedule_chain.dart';
import '../../domain/shift_rotation.dart';
import '../../state/app_settings.dart';
import '../alarm/alarm_service.dart';
import '../widget/widget_service.dart';
import 'calendar_lens.dart';
import 'lens_warp_scope.dart';
import 'calendar_range_band.dart';
import 'range_band.dart';
import 'schedule_management_screen.dart';
import 'schedule_span_label.dart';
import 'shift_override_picker.dart';

/// 量一段文字在给定样式与缩放下的宽度。
///
/// 顶栏那个「一行放不放得下」的判据用它（见 `_oneRowFits`）—— 与
/// `schedule_editor_screen.dart` 里那个私有的同款；两边各自私有，不为一个十行的
/// 小函数开一个共享件。
double _textWidth(String text, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  return painter.width;
}

/// 与**这个月**有关、且只跟**方案本身**有关的那一样（见 `_factsFor`）。
///
/// 它原来每次重建都要重算（整月 × 一次链查询），而输入只跟
/// 「哪个月 / 哪条链」有关 —— 与「选中哪天」「这一帧那枚块在哪」都无关。
@immutable
class _MonthFacts {
  const _MonthFacts({required this.hasNoSchedule});

  /// 整月**一天班表都没有**（指路那层用它判要不要盖）。
  final bool hasNoSchedule;
}

/// 那枚块**这一帧**的状态：在哪、多快、速度是不是「活的」。
///
/// 存在的理由：这三个值原来住在整页的 `State` 里，每帧 `setState` ⇒ **整页重建**
/// （实测 436 个 widget/帧，而标准档同场景 6 个）。搬进 `FrameNotifier` 之后，
/// 重建范围只剩「那枚块那一层」与「被挤的那几格」。
@immutable
class BlockFrame {
  const BlockFrame({
    required this.pos,
    required this.velocity,
    required this.live,
  });

  /// 块左上角（格层坐标）。
  final Offset pos;

  /// 速度（px/s，逻辑像素）。二维都认。
  final Offset velocity;

  /// 这一帧的速度有没有来源：手指在拖，或者块自己在滑行。
  ///
  /// 与从前 `velocityLive: _dragActive || _flying` 同一个判据 —— 松手之后父层
  /// **不归零**（留给透镜自己衰减），所以这个标志还得管住「别把陈旧的反复灌回来」。
  final bool live;

  /// `publish` 靠 `==` 挡掉重复写：拖动中同一帧被重建两次是常态。
  @override
  bool operator ==(Object other) =>
      other is BlockFrame &&
      other.pos == pos &&
      other.velocity == velocity &&
      other.live == live;

  @override
  int get hashCode => Object.hash(pos, velocity, live);
}

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen>
    with SingleTickerProviderStateMixin {
  static const _hPad = 12.0; // 网格左右留白
  static const _weekdayH = 26.0; // 周标题行高
  static const _cellInset = AppTokens.gapHair; // 格子/玻璃块统一内缩

  /// 格子卡片与选中块的圆角：**必须同源**。
  ///
  /// 选中块就盖在同一格上（同 inset、同尺寸），圆角差一档，四个角就会露出底下
  /// 的卡片。v0.7.3 真机实测正是如此：块是 `radiusL`(22)、卡片是 `radiusM`(16)，
  /// 四个角各露出一条约 4dp 的月牙，看起来就是「滑块没把格子盖住」。
  ///
  /// 两处都从这一个来源取，`calendar_screen_test` 里另有一条用例钉着两者相等
  /// —— 光靠自觉，这两个数迟早还会各走各的。
  static BorderRadius get _cellRadius =>
      BorderRadius.circular(AppTokens.radiusM);

  /// 这一页光晕背景的强度（`FlowingBackground.intensity`）。
  ///
  /// 响铃界面用满 1.0 —— 那是它的主角、只出现几秒。日历页是天天停留的一页，而且
  /// **大半被 92% 不透明的格子盖住**（浅色下格底是 `Colors.white` 0.92），光晕主要
  /// 从三处透出来：格子之间的缝、网格四周的留白、以及**信息卡那块真正的磨砂**
  /// （它是全页最大的一片 `BackdropFilter`）。深色下格底只有 6% 白，光晕透得更足，
  /// 所以同一档强度在深色里本来就更明显 —— 这也是它先按浅色调、再回来看深色的原因。
  static const double _bgIntensity = 0.65;

  late DateTime _month; // 显示月的 1 号
  late DateTime _selected; // 选中的日期（默认今天）
  /// 底部信息卡是否展开。默认收起成一个小条；点格子某天或点它展开。
  bool _infoCardExpanded = false;

  bool _pressed = false; // 按下膨胀
  bool _dragActive = false; // 拖拽中（跟手，无过渡）
  double _visualCol = 0; // 选中块视觉列（连续小数，拖动时用）
  double _visualRow = 0; // 选中块视觉行（连续小数，拖动时用）
  double _grabCol = 0; // 手指相对选中块左缘的抓取偏移（列）
  double _grabRow = 0; // 手指相对选中块上缘的抓取偏移（行）

  /// 当月每行网格的实际高度（行内等高：该行最多几个胶囊就多高）。
  /// 由 `_dayRows` 每帧算一次，坐标换算（点选 / 拖选 / 玻璃块 / 水带）都读它。
  List<double> _rowHeights = const [];

  /// 选中块的拖动速度（px/s，逻辑像素）—— 帧间差分 ÷ 真实帧间隔（`lensVelocityStep`，
  /// 一处实现、带低通）。**只有液态档那枚块读它**：标准档那枚是等比放大，不吃速度。
  double _vx = 0;
  double _vy = 0;

  /// 上一帧的帧戳与「那一帧块在哪一格」。`null` = 这一段拖动还没量过速度。
  Duration? _lastFrameStamp;

  /// 每分钟刷新一次，让今天格的倒计时保持最新。
  Timer? _minuteTimer;
  double _lastVelCol = 0;
  double _lastVelRow = 0;

  // ── 滑行：点日期 / 点「今天」那一下，那枚块**自己飞过去**（只有液态档）──────
  //
  // 为什么位置要由我们自己算：`AnimatedPositioned` 走的时候我们**看不到中间位置**，
  // 于是 ① 速度恒为 0（形变与彩边都不发生）② 挤压场一直盯着**终点那一格**（块飞过的
  // 格子一点反应都没有）。位置一旦由我们算，速度、挤压场、以及画出来的那一帧就是
  // 同一个数推出来的 —— 用户 2026-10-01 说的「返回的动画还是以前那种效果」就是它。
  //
  // 标准档**一个字节都不走这条路**：那里 `lensCenter` 是 null、速度也没人消费，跑起来
  // 只是白付每帧重建 —— 那棵树仍旧由 `AnimatedPositioned` 自己走（逐像素不变）。
  Ticker? _ticker;
  bool _flying = false;

  /// 这一帧那枚块在哪儿（格子层坐标，与 `blockLeft/blockTop` 同一套）。
  /// 拖动中它就是手指的位置，滑行中它是算出来的中间位置。
  Offset _flightPos = Offset.zero;
  Offset? _flightFrom; // 这一趟的起点（null = 没有在跑的滑行）
  Offset? _flightTarget; // 上一次摆过的目标（null = 块不在树上）

  /// 滑行速度的换算要用格子尺寸，而那两个数只在 build 里算得出来 —— 起跑那一帧
  /// 存下来（中途换窗口大小会差一档，那也是下一帧就自愈的事）。
  double _flightCellW = 1;
  double _flightCellH = 1;

  /// 这一趟滑行已经走了多久。**自己累加，不拿 ticker 的 `elapsed`** —— 那个基准是
  /// ticker 自己的（停掉再开会不会归零不在我们手上），而这里只要帧间隔。
  Duration _flightElapsed = Duration.zero;
  Duration? _lastFlightStamp;

  /// 滑行的曲线与时长 —— **与标准档那棵树完全同一套**（`AnimatedPositioned` 用的
  /// 就是这两个数），这样两档飞得一样快、一样刹车。
  static const Curve _blockSlideCurve = Curves.easeOutCubic;
  static const Duration _blockSlideDuration = AppTokens.durMed;

  /// 长按拖选：起点与当前终点（null = 不在范围选择态）。
  DateTime? _rangeAnchor;
  DateTime? _rangeFocus;

  /// 多选态那枚带子**这一帧淌到了哪儿**（格坐标，含鼓出）。
  ///
  /// 挤字的场要用它，而场必须跟着**淌着的那一点**走：停在「末端吸附到的那一格」的
  /// 中心等于不挤（那一格的 `t` 恒为 0）。带子每帧把位置回调上来（`onTipPos`）。
  double? _rangeTipPos;

  /// 与**这个月**有关、且**只跟方案本身**有关的那样 —— 一次算好，键变了才重量。
  ///
  /// 为什么只关它、而不关「有没有未完成的待办」与「有没有被按天调过」：后面两样依赖
  /// **数据**（待办表、按天覆盖表），关进缓存就会在「调整了一次班次」之后拿到旧值。
  /// 它们本来也便宜（一次扫待办 / 整月 `scheduleOn`），现算即可。
  ///
  /// 键用 [ScheduleChain.cacheKey] 就够：这一样只问「那天有没有班表在管」
  /// （`hasScheduleOn`），而它只看段表与兜底那套在不在 —— `cacheKey` 两者都含。
  /// 按天改班 / 周期 / 基准日那些不影响它，用更宽的 [ScheduleChain.rotationKey]
  /// 只会让「调一次班」之后白算一遍整月遍历。
  _MonthFacts _factsFor(ScheduleChain? chain) {
    final String key = <String>[
      _month.year.toString(),
      _month.month.toString(),
      chain?.cacheKey ?? '-',
    ].join('|');
    if (key == _factsKey && _facts != null) return _facts!;
    final _MonthFacts f =
        _MonthFacts(hasNoSchedule: _computeMonthHasNoSchedule(chain));
    _factsKey = key;
    _facts = f;
    return f;
  }

  _MonthFacts? _facts;
  String? _factsKey;

  /// 这一帧「挤压场的中心」—— 42 格那层读它（`LensWarpScope`）。
  ///
  /// ⚠️ **只许从 [_publishFrame] 写**：帧间（`Ticker` / 指针 / 带子回调）用
  /// `publish`，帧内（`_gridBody` 里那个 `LayoutBuilder` 跑在**布局阶段**）必须
  /// `silent: true` —— 在那里通知会当场抛「setState() called during build」，
  /// 而静默写照样能在同一帧被读到（读的人每帧现读，见 `FrameBuilder`）。
  final FrameNotifier<Offset?> _lensCenter = FrameNotifier<Offset?>(null);

  /// 「此刻有东西在动」：拖动 / 滑行 / 多选拖选。
  ///
  /// 光晕拿它暂停（见 `FlowingBackground.pauseWhen`）—— 那些交互本来每帧都在画，
  /// 而光晕每 340ms 插进来一帧就是一次固定掉帧。
  ///
  /// ⚠️ **判据是「这一帧有没有东西在产出」，不是「手指按着」。** [_publishFrame]
  /// 只在真有运动源推帧时才被调用：滑行的 tick、拖动中**有位移**的指针事件、
  /// 带子末端在淌、以及换月时那个每帧重建整页的 `AnimatedSwitcher`。
  /// **手指按住不动时谁都不调它**，而那时屏幕上没有任何东西在变 —— 把光晕也冻住
  /// 是没有理由的（v0.10.21 之前判的是 `_dragActive`，按住就停，那是错的）。
  final ValueNotifier<bool> _interacting = ValueNotifier<bool>(false);

  /// 「动」的判定天然是**一帧一帧续**的：每一帧末无条件放掉，下一帧谁在动谁再置位。
  ///
  /// 于是运动源一停，光晕 340ms 后就接着走（`_t` 从没被推进过 ⇒ 恢复时不跳回）。
  /// 用 `addPostFrameCallback` 而不是 `Timer`：帧末必然跑到，而定时器会在
  /// 「已经没人动了」之后还挂着一条待处理项（widget 测试会因此报
  /// 「A Timer is still pending」）。
  bool _interactingClearScheduled = false;

  /// 这一帧有没有运动源推帧。
  bool _motionThisFrame = false;

  void _markInteracting() {
    _motionThisFrame = true;
    _syncInteracting();
    if (_interactingClearScheduled) return;
    _interactingClearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _interactingClearScheduled = false;
      _motionThisFrame = false;
      _syncInteracting();
    });
  }

  /// 「此刻有没有东西在动」。写的是 `ValueNotifier`（监听者只起停 `Timer`、
  /// 不 `setState`），所以帧内（布局阶段）那一处也写得。
  void _syncInteracting() {
    if (!mounted) return;
    _interacting.value = _motionThisFrame;
  }

  /// 那枚块这一帧的状态（位置 / 速度 / 速度是不是活的）—— 只由 [_publishFrame] 写。
  final FrameNotifier<BlockFrame> _blockFrame =
      FrameNotifier<BlockFrame>(const BlockFrame(
          pos: Offset.zero, velocity: Offset.zero, live: false));

  /// 把这一帧的两个每帧值一起发出去。
  ///
  /// ⚠️ **两个通知源只从这一个方法出去**（各自写迟早会各说各话）。
  /// ⚠️ 调用点分两类：**帧间**（`Ticker` / 指针回调）默认通知；**帧内**
  /// （`_gridBody` 里那个 `LayoutBuilder` 跑在**布局阶段**）必须 `silent: true`
  /// —— 在那里通知会当场抛「setState() called during build」，而静默写照样能在
  /// 同一帧被读到（读的人每帧现读，见 `FrameBuilder`）。
  void _publishFrame({required Offset? center, bool silent = false}) {
    // 这一帧有东西在产出 ⇒ 把光晕停住（见 [_markInteracting] 那段说明）。
    _markInteracting();
    final BlockFrame f = BlockFrame(
      pos: _flightPos,
      velocity: Offset(_vx, _vy),
      live: _dragActive || _flying,
    );
    if (silent) {
      _lensCenter.publishSilently(center);
      _blockFrame.publishSilently(f);
    } else {
      _lensCenter.publish(center);
      _blockFrame.publish(f);
    }
  }

  /// 信息卡最后那行「本月 早12 · 午8 · 夜8 · 休6」：**整个月**各上几天什么班。
  ///
  /// 数整月而不是数到今天为止 —— 于是同一月里每天这一行完全一样、量出来的高度也
  /// 一样，判定它画不画的时候不必按天重量。班次用 `shortLabel`（日历格子里那个
  /// 一到两个字的简称：早 / 午 / 夜 / 休，英文是 M / A / N / O），一行放得下；
  /// 班次多的排班会折到第二行，折行的高度也照量（见 `measureInfoCardLine`）。
  ///
  /// 实现在 `domain/day_summary.dart` 的 [monthTallyFor] —— 桌面小组件的今日卡
  /// 要用**同一份**（那边按月查，见 `widget_snapshot.dart`）。

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _month = DateTime(n.year, n.month, 1);
    _selected = dateOnly(n);
    WidgetService.widgetLaunchRequested.addListener(_onWidgetLaunchRequested);
    // 冷启动 / 小组件点击时本页尚未挂载（HomeShell 先 `jumpToPage(0)`、下一帧才建出
    // 本页）：那一刻的通知没人接，值会滞留在 notifier 上。这里补一次同步读取，
    // 把「已经落在 notifier 里的跳转意图」落到网格上 —— 否则热启动从别的 tab 切回
    // 日历时选中的还是今天。**不走 `_onWidgetLaunchRequested`**：那里 `setState` 在
    // `initState` 里是多余的（首帧本来就要 build），直接赋值即可。
    final pending = WidgetService.widgetLaunchRequested.value;
    if (pending != null) {
      WidgetService.widgetLaunchRequested.value = null;
      _month = DateTime(pending.year, pending.month, 1);
      _selected = dateOnly(pending);
    }
    // 每分钟刷一次，让今天格的倒计时保持最新（D29）。
    // 定时器在切走 tab 时仍会触发（PageView 不销毁子页），
    // 但 setState 在离屏 widget 上开销可忽。
    _minuteTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetService.widgetLaunchRequested.removeListener(_onWidgetLaunchRequested);
    _lensCenter.dispose();
    _blockFrame.dispose();
    _interacting.dispose();
    _ticker?.dispose();
    _minuteTimer?.cancel();
    super.dispose();
  }

  /// 用户在桌面小组件上点了某一天。
  ///
  /// 消费完由**这里**把 notifier 置回 null（不是 HomeShell）—— HomeShell 只负责
  /// 切到日历页，切完还得有人把日期落到网格上。置回会再触发一次监听，
  /// 靠开头那句「值为 null 就返回」兜住，不会递归。
  void _onWidgetLaunchRequested() {
    final d = WidgetService.widgetLaunchRequested.value;
    if (d == null) return;
    WidgetService.widgetLaunchRequested.value = null;
    if (!mounted) return;
    setState(() {
      _month = DateTime(d.year, d.month, 1);
      _selected = dateOnly(d);
    });
  }

  /// 换月动画的方向：`+1` 往后的月份、`-1` 往前的月份。
  ///
  /// 换月动画要「往哪翻就从哪边进来」，所以方向不能写死。`_today` 与月份选择器
  /// 可能一次跳好几个月，一律按实际前后关系定，不按点了哪个键。
  int _monthRoll = 1;

  /// 换月都要走这里：定方向 + 换月。月份没变就什么都不做（`_today` 在本月内点
  /// 一下不该触发一次动画）。
  void _setMonth(DateTime m) {
    final next = DateTime(m.year, m.month, 1);
    if (next == _month) return;
    setState(() {
      _monthRoll = next.isAfter(_month) ? 1 : -1;
      _month = next;
    });
  }

  void _prev() => _setMonth(DateTime(_month.year, _month.month - 1, 1));
  void _next() => _setMonth(DateTime(_month.year, _month.month + 1, 1));
  void _today() {
    final n = DateTime.now();
    setState(() {
      // 今天跳回本月要不要滑、往哪边滑，同样按前后关系定。
      _monthRoll = DateTime(n.year, n.month, 1).isAfter(_month) ? 1 : -1;
      _month = DateTime(n.year, n.month, 1);
      _selected = dateOnly(n);
    });
  }

  Future<void> _showMonthPicker() async {
    final picked = await showGlassMonthPicker(context, initialMonth: _month);
    if (picked != null && mounted) {
      _setMonth(picked);
    }
  }

  /// 换月那一下位移：往前翻往左走、往后翻往右走，两头都带淡入淡出。
  ///
  /// **只包「随月份变的那部分」** —— 网格，以及年月胶囊里那几个字。顶栏那几个圆形
  /// 按钮不包：它们不随月份变，跟着一起滑会显得整条顶栏在晃。
  ///
  /// 换月只有「‹ ›」和月份选择器两条路径（网格上没有横向手势，横向拖动归底栏导航），
  /// 所以这个位移不会跟任何手势打架。
  Widget _monthSlide({
    required DateTime month,
    required String tag,
    required Widget child,
  }) =>
      AnimatedSwitcher(
        duration: AppTokens.durMed,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        // 默认把两个孩子**居中**堆叠；5 行的月份换 6 行的月份时两者高度不同，居中
        // 会让旧的那版上下错开半行。按上沿对齐才是「一页换一页」。
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, if (current != null) current],
        ),
        transitionBuilder: (child, animation) {
          // 进来的那个是当前月份（从翻页那一侧滑入），出去的是上一个月（往反方向
          // 滑走）—— 两个孩子方向相反，而 `AnimatedSwitcher` 给它们的 `animation`
          // 是同一个（一个正向、一个反向），光看 `animation` 分不出谁是谁，所以让
          // 每个孩子自己带上月份来分（[_MonthPane]）。
          final pane = child as _MonthPane;
          final dir = pane.month == month ? _monthRoll : -_monthRoll;
          // ⚠️ **换月也算「在动」**，而它得靠这一层带进来：整个转场里用的是**同一个
          // `_MonthPane` 实例**，子树不会每帧重建，所以 `_buildGrid` 里那一处
          // `_publishFrame` 只在 `setState` 那一帧跑一次、不是每帧。
          // （第一版就是这么以为的 —— 注释还写成了「换月那个每帧重建整页的
          // AnimatedSwitcher」，于是那条用例其实什么都没验：换月动画 220ms
          // 比光晕一步的 340ms 还短，即使完全不暂停也看不出差别。最终审查抓出来的。）
          return _MonthRollWatcher(
            animation: animation,
            onFrame: _markInteracting,
            child: FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                // 位移只要一小段（卡片宽度的 6%），其余观感交给淡入淡出 —— 整屏
                // 宽度那种滑法在月历上太闹。
                begin: Offset(0.06 * dir, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
            ),
          );
        },
        child: _MonthPane(
          key: ValueKey('$tag-${month.year}-${month.month}'),
          month: month,
          child: child,
        ),
      );

  int get _leading => DateTime(_month.year, _month.month, 1).weekday - 1;
  int get _daysInMonth => DateTime(_month.year, _month.month + 1, 0).day;

  /// 本月网格占几行（含月初的空格）。
  int get _weekRows => (_leading + _daysInMonth + 6) ~/ 7;

  /// 第 [row] 行的顶部 Y（周标题之下累加行高）。
  double _rowTop(int row) {
    if (_rowHeights.length != _weekRows) return _weekdayH + row * 58; // 还没算出来
    var top = _weekdayH;
    for (var i = 0; i < row && i < _rowHeights.length; i++) {
      top += _rowHeights[i];
    }
    return top;
  }

  /// 网格内容总高度（周标题 + 各行累加）。
  double get _gridContentH {
    if (_rowHeights.length != _weekRows) return _weekdayH + _weekRows * 58;
    return _weekdayH + _rowHeights.fold(0.0, (a, b) => a + b);
  }

  /// Y 坐标 → 行号（越界返回 -1 或 _weekRows）。
  int _rowFromY(double y) {
    if (y < _weekdayH) return -1;
    if (_rowHeights.length != _weekRows) {
      return ((y - _weekdayH) / 58).floor();
    }
    var top = _weekdayH;
    for (var r = 0; r < _rowHeights.length; r++) {
      if (y < top + _rowHeights[r]) return r;
      top += _rowHeights[r];
    }
    return _rowHeights.length;
  }

  /// 连续视觉行 → Y（拖拽时块在行间按比例走）。
  double _visualRowToY(double visualRow) {
    final r0 = visualRow.floor().clamp(0, _weekRows - 1);
    final r1 = (r0 + 1).clamp(0, _weekRows - 1);
    final frac = (visualRow - r0).clamp(0.0, 1.0);
    return _rowTop(r0) + (_rowTop(r1) - _rowTop(r0)) * frac;
  }

  /// Y → 连续视觉行（反向，拖拽跟手用）。
  double _yToVisualRow(double y) {
    if (_rowHeights.length != _weekRows) {
      return (y - _weekdayH) / 58;
    }
    if (y <= _weekdayH) return 0;
    var top = _weekdayH;
    for (var r = 0; r < _rowHeights.length; r++) {
      if (y < top + _rowHeights[r]) {
        final frac = ((y - top) / _rowHeights[r]).clamp(0.0, 1.0);
        return r + frac;
      }
      top += _rowHeights[r];
    }
    return _rowHeights.length.toDouble();
  }

  /// 某个日期在网格中的槽位矩形；不在本月返回 null。
  ///
  /// 多选态那条水带也用它 —— 它要的是「会动的那一头在哪一格」。
  Rect? _cellRect(DateTime date, double cellW, double cellH) {
    final first = DateTime(_month.year, _month.month, 1);
    final index = daysBetween(first, date) + _leading;
    if (index < _leading || index >= _leading + _daysInMonth) return null;
    final row = index ~/ 7;
    final col = index % 7;
    return Rect.fromLTWH(
        _hPad + col * cellW, _rowTop(row), cellW, _rowHeights[row]);
  }

  Rect? _selectedRect(double cellW, double cellH) =>
      _cellRect(_selected, cellW, cellH);

  /// 手指位置 → 那一格的日期（越界 / 空格 / 不是本月都返回 null）。
  DateTime? _dateFromPosition(Offset pos, double cellW, double cellH) {
    final col = ((pos.dx - _hPad) / cellW).floor();
    final row = _rowFromY(pos.dy);
    if (col < 0 || col > 6 || row < 0 || row >= _weekRows) return null;
    final index = row * 7 + col;
    if (index < _leading) return null;
    final day = index - _leading + 1;
    if (day < 1 || day > _daysInMonth) return null;
    return DateTime(_month.year, _month.month, day);
  }

  /// 点按位置 → 选中日期。**只接点按**（唯一调用点是 `onTapDown`）。
  ///
  /// 滑块「拖到新的一格」不经过这里：拖拽那一路由 `onPanEnd` 吸附
  /// （走 `_nearestDateFromVisual`），触觉也在那边发。旧注释写成「2D 拖拽/点按」，
  /// 正是这种「看着也管拖拽」的措辞把触觉引到了错的落点。
  void _selectFromPosition(Offset pos, double cellW, double cellH) {
    final date = _dateFromPosition(pos, cellW, cellH);
    if (date != null && date != _selected) {
      // 与长按拖选同一口径：**吸附到的格子真的变了**才震。原地按一下不震。
      Haptics.select();
      // 点某天 -> 信息卡展开显示那天详情（用户 2026-10-25 要求「点开具体日期弹出来」）。
      _infoCardExpanded = true;
      setState(() => _selected = date);
    }
  }

  /// [date] 是否落在长按拖选的范围里（闭区间，两端谁前谁后都算）。
  bool _inSelectedRange(DateTime date) {
    final a = _rangeAnchor, b = _rangeFocus;
    if (a == null || b == null) return false;
    final lo = daysBetween(a, b) >= 0 ? a : b;
    final hi = daysBetween(a, b) >= 0 ? b : a;
    return daysBetween(lo, date) >= 0 && daysBetween(date, hi) >= 0;
  }

  /// 长按被取消时的统一收尾：滑块那套与范围态一起熄掉。
  ///
  /// 走到这儿的都是真·取消（切前台、来电）。长按赢下竞技场之后框架只把
  /// `PointerUp` 送进 `onLongPressEnd`，取消那一支只发 `onLongPressCancel` ——
  /// 不接它，那片范围淡染会一直挂在屏幕上，直到下一次长按。
  void _clearGestureState() {
    if (!_pressed &&
        !_dragActive &&
        _rangeAnchor == null &&
        _rangeFocus == null) {
      return; // 没有状态可清：不为一次无关的取消白白重建整棵网格
    }
    setState(() {
      _pressed = false;
      _dragActive = false;
      _rangeAnchor = null;
      _rangeFocus = null;
    });
  }

  /// 松手时：由选中块的连续视觉位置吸附到最近一格，返回该格日期（越界/空格返回 null）。
  DateTime? _nearestDateFromVisual() {
    final col = _visualCol.round();
    final row = _visualRow.round();
    if (col < 0 || col > 6 || row < 0) return null;
    final index = row * 7 + col;
    if (index < _leading) return null;
    final day = index - _leading + 1;
    if (day < 1 || day > _daysInMonth) return null;
    return DateTime(_month.year, _month.month, day);
  }

  /// 目标变了就起一次滑行。**在 `build` 里调** —— 目标本来就只在 build 里算得出来，
  /// 而目标没变时它一行都不做（同一帧里 build 跑几次是常态）。
  ///
  /// 用 `Ticker` 而不是 `AnimationController`：后者的 `forward()` 一调就会通知监听者，
  /// 在 build 里会撞「setState() called during build」。而这里只需要「每帧来一下」。
  void _syncBlockFlight(
      bool showBlock, Offset target, double cellW, double cellH) {
    if (!showBlock || !liquidGlassActive.value) {
      // 块不在树上 / 不是液态档：**清掉「上一次摆过哪儿」** —— 下次它再出现时
      // 直接落到位，不从上一处（很可能是另一个月的坐标）窜过来。
      _flightTarget = null;
      _stopFlight();
      return;
    }
    _flightCellW = cellW;
    _flightCellH = cellH;
    if (_dragActive) {
      // 拖动中位置由手指给（1:1 跟手），滑行让位。**这一条要在「目标没变」之前**：
      // 用户可能在那枚块还在飞的时候一把按住它（`onPanStart` 的目标恰好就是
      // `_selected` 那一格、与飞行的终点相同），那种帧不能当成「没变化」放过去。
      _stopFlight();
      _flightTarget = target;
      _flightPos = target;
      return;
    }
    if (_flightTarget == target) return; // 没变化（滑行途中每一帧都走到这里）
    final Offset? prev = _flightTarget;
    _flightTarget = target;
    if (prev == null) {
      // 头一次出现：直接落到位。**不飞** —— 「上一次的位置」是另一个月的坐标时
      // （换月之后块被藏起来又露出来）飞过去会从莫名其妙的地方窜出来。
      _stopFlight();
      _flightPos = target;
      return;
    }
    _flightFrom = _flightPos; // 中途被打断就从中途接着飞
    _flightElapsed = Duration.zero;
    _lastFlightStamp = null;
    _flying = true;
    // ⚠️ **ticker 只建一次，之后只 start / stop**（`SingleTickerProviderStateMixin`
    // 一个 State 只许 `createTicker` 一次）—— `CalendarLens` 那边踩过同一个坑。
    _ticker ??= createTicker(_onFlightTick);
    if (!_ticker!.isActive) _ticker!.start();
  }

  void _onFlightTick(Duration elapsed) {
    final Offset? from = _flightFrom;
    if (from == null) return; // 已经被停掉的余帧
    final Duration? prevStamp = _lastFlightStamp;
    final Duration raw = prevStamp == null ? Duration.zero : elapsed - prevStamp;
    // 掉帧时按**积分步长的上限**算（与弹簧同一条规矩）：不封顶的话卡顿那一帧会
    // 让位置瞬移，速度也跟着跳一下。
    final Duration dt = raw > Duration.zero && raw < LiquidLensSpring.maxStep
        ? raw
        : LiquidLensSpring.maxStep;
    _lastFlightStamp = elapsed;
    _flightElapsed += dt;

    final double t = (_flightElapsed.inMicroseconds /
            _blockSlideDuration.inMicroseconds)
        .clamp(0.0, 1.0);
    final Offset pos =
        Offset.lerp(from, _flightTarget!, _blockSlideCurve.transform(t))!;

    // 速度：**位置的帧间差分 ÷ 真实帧间隔** —— 与拖动那条同一个纯函数、同一道低通
    // （那里差分的是「格」，这里把像素差换算成格）。
    _vx = lensVelocityStep(
        deltaPage: (pos.dx - _flightPos.dx) / _flightCellW,
        itemW: _flightCellW,
        dt: dt,
        previous: _vx);
    _vy = lensVelocityStep(
        deltaPage: (pos.dy - _flightPos.dy) / _flightCellH,
        itemW: _flightCellH,
        dt: dt,
        previous: _vy);

    _flightPos = pos;
    if (t >= 1) _stopFlight();
    // ⚠️ **顺序要紧**：先落位、再 `_stopFlight()`（`live` 因此变 false）、**最后**才发
    // —— 这样最后一帧交出去的是「松手那一帧」，透镜那边「把最后的速度接过来、自己
    // 衰减」照样成立（v0.10.15 的裁定，别改）。
    _publishFrame(
        center: Offset(_flightPos.dx + _flightCellW / 2,
            _flightPos.dy + _flightCellH / 2));
  }

  /// 停下滑行。**速度不归零** —— 松手 / 落定之后那枚块还要靠最后一次速度把形变与
  /// 彩边**收回去**（它自己按帧衰减），归零就是「啪」地一下没了。
  void _stopFlight() {
    _flying = false;
    _flightFrom = null;
    _ticker?.stop();
  }

  @override
  Widget build(BuildContext context) {
    final scheduleAsync = ref.watch(activeScheduleProvider);
    // 整页按**天**解析：某天归哪套方案由链回答（spec §2 ②），所以下面
    // 「网格 / 信息卡 / 本月统计 / 已调班」全都只认它，不再认「当前方案」。
    final chain = scheduleAsync.valueOrNull?.chain;
    ref.watch(appSettingsProvider.select((s) => s.language)); // 语言切换时重建（**只订阅语言** —— 全量 watch 会让拨触觉开关也白重建整页）
    ref.watch(appSettingsProvider.select((s) => s.showLunarDay)); // 农历开关切换时重建

    return Scaffold(
      // 玻璃要有东西可透（见 `FlowingBackground`）：底色仍是主题给的那块平坦中性色，
      // 光晕叠在它上面。在此之前整页唯一的「流光」只出现在响铃界面，日历页是一块纯色
      // —— 满页磨砂其实没在磨东西，只靠高光与描边撑着。
      //
      // 包在 `SafeArea` **外面**：它是整页的底，不该被安全区切掉边。两层包在一行里，
      // 好让下面这一大段内容保持原缩进、不制造一片只有空白的 diff。
      body: FlowingBackground(
        intensity: _bgIntensity,
        // 拖动 / 滑行 / 拖选的时候把它停住（每 340ms 一次的固定掉帧就出在这儿）。
        pauseWhen: _interacting,
        // 这一页天天停留，「高级材质」一关就别再推动背景了（见那个参数的说明）。
        freezeWhenBlurDisabled: true,
        child: SafeArea(child: Builder(builder: (context) {
          final layout = AppLayout.of(context);
          final grid = Expanded(
            // 给下面两支宽屏的几何用例一个抓手。
            key: const Key('calendar-grid'),
            // 网格区高度要先量出来，才能决定格子长多高（见 _buildGrid）。
            child: LayoutBuilder(
              builder: (context, c) => scheduleAsync.isLoading && chain == null
                  ? const GlassLoading()
                  // 网格可滚动：格子保持全尺寸，小屏 6 行放不下时滚动而非被裁切，
                  // 避免底部行与信息卡重叠。
                  : SingleChildScrollView(
                      child: _monthSlide(
                        month: _month,
                        tag: 'grid',
                        child: _buildGrid(context, chain, c.maxHeight),
                      ),
                    ),
            ),
          );

          // 宽屏两支共用的右栏。
          Widget rail() => SizedBox(
                key: const Key('info-rail'),
                width: _railWidth(layout),
                child: _sideRail(context, chain),
              );

          // **三支，不是两支。**
          //   · 宽横屏（平板 / 车机）→ 新版式：顶栏进左栏、今日卡贴右下；
          //   · 宽且矮（手机横屏）  → **今天的版式原样保留**，只多一层让位；
          //   · 其余                → 竖屏版式，一个像素不动。
          // ⚠️ 第二支存在的唯一理由：分栏判据换成 `isWideLandscape` 之后，900×420
          // 会掉进竖屏那一支、被 `if (!layout.isShort)` 把网格整块删掉 ——
          // 界面上只会少一块，**不报任何错**。
          if (layout.isWideLandscape) {
            // 顶栏在**左栏里面**（与网格一起），所以这一支不套外层 Column。
            return Padding(
              padding: const EdgeInsets.only(bottom: kNavCapsuleInset),
              child: Row(
                // **`stretch` 是这一支的核心**：右栏必须**占满整列高**，
                // 「今日卡贴右下角」才有意义。用 `start` 的话右栏会收缩到卡片高度
                // （实测 1280×800 下只有 308），于是「贴底」与「顶对齐」看起来一样 ——
                // Task 4 的用例第一版就是这么变成一句空话的。
                // 左栏不受影响：它本来就有 `Expanded` 的子件，高度恒被拉满。
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      // **必须 `start`**：顶栏在宽横屏下会收缩到内容宽度，而 `Column`
                      // 默认的 `crossAxisAlignment: center` 会把它摆到左栏正中
                      // （实测 1280 下左缘落在 270.75）—— 设计要的是贴着左缘。
                      // 网格那一支不受影响：`Expanded` 里的 `LayoutBuilder` 拿到的
                      // 松约束 `maxWidth` 仍是整栏宽，它按 `constraints.biggest` 铺满。
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [_header(context), grid],
                    ),
                  ),
                  const SizedBox(width: AppTokens.spaceMd),
                  rail(),
                ],
              ),
            );
          }

          // ⚠️ **判据是 `isWide && isShort`，不能只写 `isWide`。**
          // 只写 `isWide` 的话，**竖着的平板**（800×1280）也落进这一支、被拆成左右
          // 两栏 —— 而 spec §4.1 要修的恰恰是这处怪相（七列格子要的是宽度，
          // 不是分栏）。加上 `isShort` 之后，这一支就只剩「宽且矮」的手机横屏。
          // 独立审查抓出来的（`calendar_screen_test.dart` 的「竖着的平板」钉着）。
          if (layout.isWide && layout.isShort) {
            // 宽屏左右分栏：网格与信息卡并排，网格拿到的可用高度从
            // 「减去底部信息卡」变成「整屏高度」，格子不用再被压扁。
            // 底下那 96 是给悬浮导航胶囊让位（从前没有它，最后一行被压在胶囊下）。
            return Column(
              children: [
                _header(context),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: kNavCapsuleInset),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        grid,
                        const SizedBox(width: AppTokens.spaceMd),
                        rail(),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }

          return Column(
            children: [
              _header(context),
              // 小窗（isShort）从前在这里隐藏网格给信息卡让位；卡已删（D31），
              // 那个理由跟着消失 —— 网格任何时候都画（D36 的处方，先落这一半）。
              grid,
              // v0.14 恢复：选中那天的详情卡（信息从格子移来这里）。
              // 底部留出悬浮导航胶囊的高度 —— 否则收起的小条正好在屏幕底、
              // 被导航胶囊盖住（用户 2026-10-25 反馈）。
              Padding(
                padding: EdgeInsets.fromLTRB(AppTokens.spaceLg, AppTokens.spaceSm,
                    AppTokens.spaceLg, kNavCapsuleInset),
                child: _infoCard(context, chain),
              ),
            ],
          );
        })),
      ),
    );
  }

  /// 宽屏右栏的宽度：按屏宽取比例，再夹在 280~340。
  ///
  /// 为什么不是写死 300（本版之前的做法）：720/800 这种刚过线的宽度上，
  /// 写死 300 会把左栏挤到 360（格子 48dp）；比例 + 上下限在小屏上收窄右栏、
  /// 把宽度让给日历。
  double _railWidth(AppLayout layout) =>
      (layout.availableWidth * 0.27).clamp(280.0, 340.0);

  /// 宽屏右栏（v0.14 恢复：选中那天的详情卡，信息从格子移来这里）。
  ///
  /// 0.13.0 曾把信息卡删掉、信息合并进格子（那版格子三行：日期/首末时段/农历）；
  /// v0.14 格子改成参考图样式（日期 + 时段胶囊列表），从格子里移出的农历、倒计时、
  /// 已调班、节假日与班次名都在这一张卡里补上 —— 格子回答「哪天、几点」，
  /// 卡片回答「还有什么细节」。
  Widget _sideRail(BuildContext context, ScheduleChain? chain) =>
      _infoCard(context, chain);

  /// 选中那天的详情卡（竖屏底部 / 宽屏右栏）。
  Widget _infoCard(BuildContext context, ScheduleChain? chain) {
    final showLunarDay = ref.watch(
        appSettingsProvider.select((s) => s.showLunarDay)); // 农历开关
    final lunar = lunarOf(_selected);
    final shifts = chain?.shiftOn(_selected) ?? const [];
    final isToday = isSameDay(_selected, dateOnly(DateTime.now()));
    final muted = AppTokens.inkMuted(context);
    final primary = Theme.of(context).colorScheme.primary;
    final daySchedule = chain?.scheduleOn(_selected);
    final isAdjusted =
        daySchedule?.dayOverrides.containsKey(dayNumber(_selected)) ?? false;

    // 日期行（收起态也显示这条，作折叠把手）。
    final dateRow = Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: shifts.isNotEmpty ? Color(shifts.first.color) : primary,
            borderRadius: BorderRadius.circular(AppTokens.radiusS),
          ),
        ),
        const SizedBox(width: AppTokens.gapIconTextLg),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(L10n.monthDay(_selected),
                maxLines: 1,
                style: AppTokens.sectionTitle),
          ),
        ),
        if (isToday) ...[const SizedBox(width: AppTokens.spaceSm), _todayBadge(context)],
        const Spacer(),
        // 展开/收起箭头。
        InkWell(
          onTap: () => setState(() => _infoCardExpanded = !_infoCardExpanded),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              _infoCardExpanded
                  ? Icons.keyboard_arrow_down
                  : Icons.keyboard_arrow_up,
              size: AppTokens.iconMd,
              color: muted,
            ),
          ),
        ),
      ],
    );

    // 收起态：只显示日期行 + 班次一段（够认出选的是哪天），点日期行也展开。
    if (!_infoCardExpanded) {
      return GlassTile(
        key: const Key('info-card-collapsed'),
        translucentFill: false,
        padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceLg, vertical: AppTokens.spaceSm),
        child: InkWell(
          onTap: () => setState(() => _infoCardExpanded = true),
          child: dateRow,
        ),
      );
    }

    return GlassTile(
      key: const Key('info-card-expanded'),
      translucentFill: false,
      padding: const EdgeInsets.fromLTRB(
          AppTokens.spaceLg, AppTokens.spaceMd, AppTokens.spaceLg, AppTokens.spaceMd),
      child: ConstrainedBox(
        // 展开态限高：内容超过屏内剩余时卡内滚动，**不把网格挤出去**
        // （用户 2026-10-25 反馈「日历把卡片内容挤出去了」）。
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.45),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              dateRow,
          // 班次列表：每个班次的每个时段段一行（色点 + 班次名 + 时段）。
          if (shifts.isNotEmpty) ...[
            const SizedBox(height: AppTokens.spaceSm),
            for (final shift in shifts) ...[
              _shiftRow(context, shift),
              const SizedBox(height: AppTokens.gapHair),
            ],
          ],
          // 农历（含节假日名；跟随「我的 → 显示农历」开关）。
          if (showLunarDay) ...[
            const SizedBox(height: AppTokens.spaceXs),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                lunar.isLegalHoliday && lunar.holidayName.isNotEmpty
                    ? '${lunar.shortLabel} · ${lunar.holidayName}'
                    : lunar.isMakeupWorkday
                        ? '${lunar.shortLabel} · 调休上班'
                        : lunar.shortLabel,
                maxLines: 1,
                style: AppTokens.rowSecondary.copyWith(
                  color: lunar.isLegalHoliday
                      ? AppTokens.holiday
                      : lunar.isMakeupWorkday
                          ? Colors.orange.shade700
                          : muted,
                ),
              ),
            ),
          ],
          // 今天：倒计时。
          if (isToday) ...[
            const SizedBox(height: AppTokens.gapHair),
            Text(_countdownLine(shifts),
                maxLines: 1,
                style: AppTokens.labelSecondary.copyWith(color: primary)),
          ],
          // 已调班徽章。
          if (isAdjusted) ...[
            const SizedBox(height: AppTokens.spaceXs),
            _adjustedBadge(context, primary),
          ],
          // 本月统计。
          const SizedBox(height: AppTokens.spaceSm),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              monthTallyFor(chain, _month) ?? '',
              maxLines: 1,
              style: AppTokens.labelSecondary.copyWith(color: muted),
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }

  /// 班次一行：色点 + 班次名 + 该班次所有时段段（每段一个 `6-8` 式文本）。
  /// 右侧附「还剩 X 响铃」：该班次联动闹钟里下一条还没响的（用户 2026-10-25 要求）。
  Widget _shiftRow(BuildContext context, ShiftClass shift) {
    final segments = shift.allSegments;
    final timeText = segments
        .map((s) => s.cellLabel)
        .join(' / ');
    final ringIn = _nextAlarmRingIn(shift);
    final ringText = ringIn == null
        ? null
        : Text(ringIn,
            maxLines: 1,
            style: AppTokens.labelSecondary.copyWith(
                color: Theme.of(context).colorScheme.primary));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: AppTokens.padChipV),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
                color: Color(shift.color), shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: AppTokens.gapIconText),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(shift.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTokens.rowPrimary),
              // 班次名本身已是时段（值班制模板：班次名就叫「6-8」「22-24」）时，
              // 再显示一行 timeText 就是肉眼看到的「重复」（用户 2026-10-25 反馈）。
              // 判断：单段班次 + 名字是「X-Y」且与段的起止小时一致（22-24 的 24
              // 按 24 小时制折算成 0，与「22-0」同义）。合并成一行。
              if (timeText.isNotEmpty && !_nameIsOwnTimeText(shift)) ...[
                const SizedBox(height: AppTokens.gapHair),
                Text(timeText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTokens.labelSecondary),
              ],
            ],
          ),
        ),
        // 右侧：下一条联动闹钟还剩多久响铃。
        if (ringText != null) ...[const SizedBox(width: AppTokens.gapIconText), ringText],
      ],
    );
  }

  /// 该班次在 [selected] 那天下一条还没响的联动闹钟还剩多少分钟；
  /// 闹钟关着 / 没配 / 已全部响过返回 null。
  String? _nextAlarmRingIn(ShiftClass shift) {
    if (!shift.alarmEnabled || shift.alarms.isEmpty) return null;
    final now = DateTime.now();
    final fireAts = [
      for (final a in shift.alarms) shiftAlarmFireAt(_selected, shift, a),
    ]..sort();
    for (final fireAt in fireAts) {
      final minutes = fireAt.difference(now).inMinutes;
      if (minutes > 0) return L10n.ringIn(minutes);
    }
    return null;
  }

  /// 班次名是否就是它自己的时段文本（值班制模板「0-2」「22-24」这类）。
  /// 单段班次、且名字是「数字-数字」、起止小时与段的钟面一致（end 的 24 按 0 折算）。
  bool _nameIsOwnTimeText(ShiftClass shift) {
    final segs = shift.allSegments;
    if (segs.length != 1) return false;
    final m = RegExp(r'^(\d+)-(\d+)$').firstMatch(shift.name);
    if (m == null) return false;
    final seg = segs.single;
    final endClock = (seg.endMinute % 1440) ~/ 60;
    return int.tryParse(m[1]!) == seg.startMinute ~/ 60 &&
        int.tryParse(m[2]!)! % 24 == endClock;
  }

  /// 今天徽章（信息卡日期行旁）。
  Widget _todayBadge(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceSm, vertical: AppTokens.padChipV),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(AppTokens.radiusL),
        ),
        child: Text(L10n.today,
            style: AppTokens.microStrong.copyWith(
                color: Colors.white, fontWeight: FontWeight.w700)),
      );

  /// 「已调班」徽章（信息卡班次行尾巴）。
  Widget _adjustedBadge(BuildContext context, Color primary) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceSm, vertical: AppTokens.padChipV),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppTokens.radiusL),
          border: Border.all(color: primary.withValues(alpha: 0.45)),
        ),
        child: Text(L10n.adjustedBadge,
            style: AppTokens.microStrong.copyWith(
                color: primary, fontWeight: FontWeight.w700)),
      );

  /// 今天格倒计时文本（信息卡用）：距下一段岗次开始还有多久。
  /// 所有岗都过完（或没有未来的岗）时返回「全部结束」。
  String _countdownLine(List<ShiftClass> shifts) {
    final now = DateTime.now();
    final nowMinute = now.hour * 60 + now.minute;
    for (final shift in shifts) {
      for (final seg in shift.allSegments) {
        if (seg.startMinute > nowMinute) {
          final minutesUntil = seg.startMinute - nowMinute;
          return minutesUntil < 60
              ? L10n.countdownMin(minutesUntil)
              : L10n.countdownH(minutesUntil ~/ 60);
        }
      }
    }
    return L10n.countdownOver;
  }

  /// 顶栏那一行装不装得下 —— **按排版实测**，不拿宽度阈值猜（理由见 `_header`）。
  ///
  /// 固定件全是量得出来的：左右留白、三个圆形钮、四个 `gapIconText`、两个胶囊的
  /// 内边距、「今天」胶囊里的图标与文字；可变件只有年月那一串。
  bool _oneRowFits(BuildContext context, {bool compactToday = false}) {
    final scaler = MediaQuery.textScalerOf(context);
    // 量宽必须**带上当时那一套字体**：`Text` 会从环境继承 family（工装里中英双字体
    // 就是这么挂上去的），而裸的 `TextPainter` 只会用兜底字体 —— 两者的中文宽度
    // 差得很远（实测同一个「2026年10月」：兜底 128、真字体 86）。
    final ambient = DefaultTextStyle.of(context);
    TextStyle styled(TextStyle t) =>
        ambient.style.merge(t); // 与 `info_card_metrics` 的 `_Measure` 同一配方
    final need = 24.0 + // 左右留白 12×2
        40.0 * 3 + // 三个圆形钮
        AppTokens.gapIconText * 4 +
        8.0 * 2 * 2 + // 两个 GlassPill 的内边距（各两侧 8）
        AppTokens.iconMd +
        // 「今天」那两个字与它前面的间距：只留图标的那一档（[compactToday]）
        // 连同这两个字一起去掉 —— 这是 §2 降级顺序里的「换短串」。
        (compactToday
            ? 0.0
            : 4 + _textWidth(L10n.today, styled(AppTokens.labelStrong), scaler)) +
        _textWidth(L10n.yearMonth(_month), styled(AppTokens.titleStrong), scaler);
    return need <= MediaQuery.sizeOf(context).width;
  }

  Widget _header(BuildContext context) {
    // 上下留白归到节奏档：10 → spaceMd(12)、6 → spaceSm(8)。
    const pad =
        EdgeInsets.fromLTRB(12, AppTokens.spaceMd, 12, AppTokens.spaceSm);
    // 一行放不下就拆两行：上行只放「‹ 年月 ›」，下行放「时段总览 / 今天」。
    // 控件收到 32 见方：一是给年月腾出完整显示「2026年10月」的宽度，二是省下 10px 高度。
    //
    // **判据是排版实测，不是宽度阈值**（v0.11.12 改）。从前判的是
    // `AppLayout.isNarrow`（宽 < 360），于是「2026年10月」比「2026年9月」多一个字
    // 就悄悄溢出了 —— 用户 2026-10-13 报的正是它（真我 GT7 Pro）。
    // 固定件全是量得出来的：三个圆形钮 + 四个间距 + 「今天」胶囊，年月那串用
    // `TextPainter` 量。**大 / 特大档下走两行是常态版式**，不是应急。
    // 一行放不下时先试「今天」只留图标（省下那两个字与间距）：还能站住一行就不折行；
    // 折行是最后一档（§2 的降级顺序「折行 > 按宽缩小 > 换短串」在这里反过来用 ——
    // 这次是**先换短串、再折行**，因为折行要多占一整行高度）。
    final fullRow = _oneRowFits(context);
    final compactToday = !fullRow && _oneRowFits(context, compactToday: true);
    if (!fullRow && !compactToday) {
      const narrowSide = 32.0;
      const narrowGap = 4.0;
      return Padding(
        key: const Key('header-two-row'),
        padding: pad,
        child: Column(
          children: [
            Row(
              children: [
                _circleIcon(context, Icons.chevron_left_outlined, L10n.prevMonth,
                    _prev, size: narrowSide),
                const SizedBox(width: narrowGap),
                Expanded(
                  child: GlassPill(
                    onTap: _showMonthPicker,
                    height: narrowSide,
                    // 年月这几个字跟着网格一起滑（见 `_monthSlide`），方向才一致。
                    child: _monthSlide(
                      month: _month,
                      tag: 'pill',
                      // `FittedBox(scaleDown)` 是**兜底**：上面那个「一行放不放得下」
                      // 是预估（差几个 dp 就可能误判 —— 实测英文特大档差约 1dp），
                      // 而这里要的是「绝不省略」。设计 §2 的第 2 档降级：缩，不省略。
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
                ),
                const SizedBox(width: narrowGap),
                _circleIcon(context, Icons.chevron_right_outlined, L10n.nextMonth,
                    _next, size: narrowSide),
              ],
            ),
            const SizedBox(height: narrowGap),
            Row(
              children: [
                _circleIcon(context, Icons.timeline, L10n.scheduleTimeline,
                    _showTimeline, size: narrowSide),
                const Spacer(),
                GlassPill(
                  onTap: _today,
                  accent: true,
                  height: narrowSide,
                  // 窄档连年月都要省着放，「今天」只留图标（整屏的窄档同样如此）。
                  child: const AppIcon(
                    Icons.today_outlined,
                    size: AppTokens.iconMd,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // 年月这几个字跟着网格一起滑（见 `_monthSlide`），方向才一致。
    final monthPill = GlassPill(
      onTap: _showMonthPicker,
      child: _monthSlide(
        month: _month,
        tag: 'pill',
        // 兜底同两行档：预估差几个 dp 时缩一点，而不是省略。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            L10n.yearMonth(_month),
            maxLines: 1,
            style: AppTokens.titleStrong,
          ),
        ),
      ),
    );

    // 宽横屏下**不套 `Expanded`**：套着它就会拿到多宽撑多宽，1280 的屏上那是
    // 一条 1600px 的长条（用户 2026-10-13 报的「顶栏太长」）。整行也一起收缩到
    // 内容宽度 → 靠左。其余档位照旧撑满整行（`Expanded` 保证年月完整显示）。
    final wide = AppLayout.of(context).isWideLandscape;

    return Padding(
      // 宽横屏沿用同一个 key：它仍然是「一行档」，只是排布不同。
      key: const Key('header-single-row'),
      padding: pad,
      child: Row(
        mainAxisSize: wide ? MainAxisSize.min : MainAxisSize.max,
        children: [
          _circleIcon(
              context, Icons.chevron_left_outlined, L10n.prevMonth, _prev),
          const SizedBox(width: AppTokens.gapIconText),
          if (wide) monthPill else Expanded(child: monthPill),
          const SizedBox(width: AppTokens.gapIconText),
          _circleIcon(
              context, Icons.chevron_right_outlined, L10n.nextMonth, _next),
          const SizedBox(width: AppTokens.gapIconText),
          // 切换排班：纯图标圆形钮（省宽，保证年月完整显示）
          _circleIcon(context, Icons.timeline, L10n.scheduleTimeline,
              _showTimeline),
          const SizedBox(width: AppTokens.gapIconText),
          GlassPill(
            onTap: _today,
            accent: true,
            // accent 变体是实心主色底，内容用白（别再跟着 colorScheme.primary，
            // 那样就是主色字压在主色底上）。
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(
                  Icons.today_outlined,
                  size: AppTokens.iconMd,
                  color: Colors.white,
                ),
                // 320 宽下「今天」两个字会挤掉年月的显示宽度，窄屏只留图标。
                // 320 宽下「今天」两个字会挤掉年月的显示宽度，窄屏只留图标。
                if (!compactToday && !AppLayout.of(context).isNarrow) ...[
                  const SizedBox(width: 4),
                  Text(
                    L10n.today,
                    // 压在实心主色胶囊上的白字，「前景色已定」，不归明度两档。
                    style: AppTokens.labelStrong.copyWith(
                      color: Colors.white.withValues(alpha: 0.98),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleIcon(BuildContext context, IconData icon, String tooltip,
      VoidCallback onTap,
      {double size = 40}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      // 按压反馈 = 玻璃的 Q 弹缩放（`GlassPressable` 没有 `onTap`，点击由
      // `GestureDetector` 承载）。水波纹只该出现在弹层的 `ListTile` 里 ——
      // 这颗手搓的圆钮套 `InkWell` 会在圆外凭空多一圈波纹（spec §7）。
      // `opaque`：让整颗 40dp 都吃点击，不只在图标那点面积上。
      child: GlassPressable(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        Colors.white.withValues(alpha: 0.22),
                        Colors.white.withValues(alpha: 0.06),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.95),
                        Colors.white.withValues(alpha: 0.55),
                      ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.28 : 0.95),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: AppIcon(icon,
                size: AppTokens.iconMd,
                color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ),
    );
  }

  /// 弹「调整班次」选择层，把 [from]..[to] 这段日子改掉（或恢复轮转）。
  ///
  /// 改完必须重排闹钟：这天可能从工作班变成休班（不该响），或从休班变成夜班
  /// （要响）—— 不重排的话闹钟跟日历就对不上了。
  Future<void> adjustDays(DateTime from, DateTime to) async {
    // 过渡态：跨时段边界要**拦住**是下一个任务；此刻先按**起点那天**所属的方案
    // 办事，与从前在「只有一套」时完全一致。
    final chain = ref.read(activeScheduleProvider).valueOrNull?.chain;
    final schedule = chain?.scheduleOn(from);
    if (chain == null ||
        schedule == null ||
        schedule.isBlank ||
        schedule.classes.isEmpty) {
      // 空白表（跟随法定节假日）没有班次定义可挑，入口本来就不该出现；
      // 这里再兜一次，免得别处误调。
      return;
    }
    final days = <DateTime>[];
    final span = daysBetween(from, to);
    for (var i = 0; i <= span; i++) {
      days.add(dateOnly(DateTime(from.year, from.month, from.day + i)));
    }

    // 拖选跨了时段边界 → **拦住**。
    //
    // 选择层列的是**某一套**的班次定义，而覆盖表的主键是 `{scheduleId, day}`、
    // 按天归属 —— 放过去只能得到「列了 A 的班次、却只对 A 的日子生效」这种
    // **静默半生效**，正是最难查的那类 bug。拦住是不让用户走进那个状态，
    // 代价只是一句话。（与「不跨月拖选」同一条思路。）
    //
    // 判等用 `identical` 而不是 `==`：`ShiftSchedule` 没有 `operator ==`，
    // 两份内容相同的不同实例会被 `==` 判成不等 —— 这里问的是「是不是**同一套**」。
    for (var i = 1; i < days.length; i++) {
      final before = chain.scheduleOn(days[i - 1]);
      final here = chain.scheduleOn(days[i]);
      if (!identical(before, here)) {
        if (mounted) {
          showGlassSnack(
            context,
            L10n.spansTwoSchedules(here?.name ?? '', L10n.monthDay(days[i])),
            icon: Icons.info_outline,
          );
        }
        return;
      }
    }

    final hasOverride =
        days.any((d) => schedule.dayOverrides.containsKey(dayNumber(d)));
    final currentShifts = days.length == 1 ? schedule.shiftOn(days.single) : [];
    final current = currentShifts.isEmpty ? null : currentShifts.first;

    final choice = await showShiftOverridePicker(
      context,
      schedule: schedule,
      from: from,
      to: to,
      currentClass: hasOverride ? current : null,
      canRestore: hasOverride,
    );
    if (choice == null || !mounted) return;

    final repo = ref.read(appRepositoryProvider);
    if (choice.restore) {
      await repo.clearDayOverrides(days);
    } else {
      await repo.setDayOverrides(days, classId: choice.shift!.id!);
    }
    // 「应用改班 / 恢复轮转」落在写库之后 ——「改班」是词汇表里点名的 commit
    // 语义（`haptics.dart` 的 `commit()` 文档）。写失败就走不到这一步。
    Haptics.commit();
    await AlarmService.replanAfterScheduleChange(repo);
    if (!mounted) return;
    showGlassSnack(
      context,
      choice.restore
          ? L10n.restoredRotation(days.length)
          : L10n.adjustedDays(days.length, choice.shift!.name),
    );
  }

  /// 「排班时段」只读总览。
  ///
  /// **只读是有意的**：原来那个「切换排班」点一行就把 `isCurrent` 换过去，可它改的
  /// 只是「没被时段覆盖时的兜底」—— 时段盖满之后点它什么也不会变，用户以为按钮
  /// 坏了（那正是这一轮重做的起因）。现在它只回答「这段时间在用哪套、今天在哪一
  /// 段」，要改就去排班管理页那条时间线。
  Future<void> _showTimeline() async {
    final schedules = await ref.read(schedulesProvider.future);
    final spans = await ref.read(scheduleSpansProvider.future);
    if (!mounted) return;
    final current = ref.read(activeScheduleProvider).valueOrNull;
    final remaining = current?.current;
    final today = dayNumber(dateOnly(DateTime.now()));

    // 今天落在哪一段上（段之间不重叠，所以至多一段）—— 给那一行打勾。
    int? todaySpanId;
    for (final s in spans) {
      final from = s.startDate == null ? null : dayNumber(s.startDate!);
      final to = s.endDate == null ? null : dayNumber(s.endDate!);
      if ((from == null || today >= from) && (to == null || today <= to)) {
        todaySpanId = s.id;
        break;
      }
    }
    final byId = {for (final s in schedules) s.id: s};
    final hasPeriods = spans.isNotEmpty;

    await showGlassSheet<void>(
      context: context,
      builder: (sheetContext) => GlassPanel(
        solid: true,
        margin: const EdgeInsets.all(12),
        borderRadius:
            const BorderRadius.all(Radius.circular(AppTokens.radiusXL)),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            // **`stretch` 而不是 `start`。** 头部下面那块内容自带一圈
            // `Padding(all: 16)`，而 `start` 给子件的是**松宽度约束** —— ListView
            // （视口）会一路撑到 `maxWidth`、Padding 再给它加出左右各 16，直接横向
            // 溢出。`stretch` 给的是紧宽度，Padding 减掉 32 之后才是 ListView 该有的宽。
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 头部走共享件（把手 + 主色竖条 + 标题 + 分隔线）。
              //
              // ⚠️ **那圈 16 的 padding 只能包住头部以下的内容，不能包住整个
              // Column**（本轮修的就是它）。原来它包在最外层，于是 `GlassSheetHeader`
              // 被**二次内缩**：分隔线比另外四个弹层窄 16dp、把手低 16dp、标题也跟着
              // 与下面的行错开 —— 「五处统一头部」只成四成不算成。
              //
              // 标题是 `titleStrong`（16）—— 与另外四个弹层同角色。
              // ⚠️ 这行注释此前写着「底部弹层标题走 `dialogTitle`，与其它弹层同
              // 角色」，那是**错的**：另外四个弹层一直走 `titleStrong`，只有这里
              // 用了 `dialogTitle`（20）。v0.12.0 统一到 16。
              GlassSheetHeader(
                title: L10n.scheduleTimeline,
                // 说法与排班管理页那条时间线**同源**：一个段都没有时不说「其余
                // 时间」（没有「这一段」，「其余」就没有着落），整行写「全部
                // 日子」。两处各写一份的话，同一个状态会有两种解释。
                subtitle: hasPeriods
                    ? L10n.remainingHint
                    : (remaining == null
                        ? L10n.allDatesNoneHint
                        : L10n.allDatesHint),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceLg),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _timelineLine(
                        sheetContext,
                        label: hasPeriods ? L10n.remainingTime : L10n.allDates,
                        value: remaining?.schedule.name ?? L10n.remainingNone,
                        mutedValue: remaining == null,
                        // 今天没落在任何段上 → 今天归「其余时间」。
                        isToday: todaySpanId == null,
                      ),
                      for (final s in spans)
                        _timelineLine(
                          sheetContext,
                          label: spanRangeLabel(s.startDate, s.endDate),
                          value: byId[s.scheduleId]?.name ?? L10n.remainingNone,
                          mutedValue: byId[s.scheduleId] == null,
                          isToday: s.id == todaySpanId,
                        ),
                      const Divider(height: 1),
                      GlassPressable(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(L10n.manageTimeline),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            Navigator.of(context).push(MaterialPageRoute<void>(
                                builder: (_) =>
                                    const ScheduleManagementScreen()));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 总览里的一行：左边的勾（今天所在的那一段）+ 日期 / 「其余时间」 + 方案名。
  ///
  /// 两边都是 flex、各自省略号 —— 与排班管理页那一节同一套写法（`ListTile` 的
  /// `trailing` 在 200dp 小窗下会横向溢出）。
  Widget _timelineLine(
    BuildContext context, {
    required String label,
    required String value,
    required bool mutedValue,
    required bool isToday,
  }) {
    final muted = AppTokens.inkMuted(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
      child: Row(
        children: [
          SizedBox(
            width: AppTokens.iconMd,
            child: isToday
                ? AppIcon(Icons.check_circle_outlined,
                    size: AppTokens.iconMd,
                    color: Theme.of(context).colorScheme.primary)
                : null,
          ),
          const SizedBox(width: AppTokens.gapIconText),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTokens.rowPrimary),
          ),
          const SizedBox(width: AppTokens.spaceSm),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: mutedValue
                  ? AppTokens.rowSecondary.copyWith(color: muted)
                  : AppTokens.labelStrong,
            ),
          ),
        ],
      ),
    );
  }

  /// 网格 + （整月都没排班时）一层指路。
  ///
  /// **指路那一层必须 `IgnorePointer`**：不加的话它会吃掉网格的手势 —— 点日期、
  /// 长按拖选全失灵，而「盖了一层透明东西导致交互没了」在 widget 测试里默认照不
  /// 出来（除非专门去点一下）。用例里就是**真的点某天**再断言信息卡变了。
  Widget _buildGrid(
      BuildContext context, ScheduleChain? chain, double availHeight) {
    final body = _gridBody(context, chain, availHeight);
    if (!_factsFor(chain).hasNoSchedule) return body;
    return Stack(
      children: [
        body,
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceXl),
                // **必须是一张（近）不透明的面板**：直接铺两行字会压在格子的
                // 日期与农历上，两边都看不清（出图当场看出来的）。
                //
                // 面板**只留左右 + 顶部**：下面那句是共享空态件
                // （`EmptyState`，v0.12.0 收口），它自带 `all(spaceLg)` 留白 ——
                // 面板再留一份纵向就会叠成 `12 + 16`。标题自己留顶部那 12。
                // `SingleChildScrollView`：小窗里网格被信息卡挤矮、空态内容
                // 放不下时滚动而不是溢出（v0.14 行高变小后网格更矮、这里更常见）。
                child: SingleChildScrollView(
                  child: GlassPanel(
                    solid: true,
                    padding: const EdgeInsets.fromLTRB(
                        AppTokens.spaceLg, AppTokens.spaceMd, AppTokens.spaceLg, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(L10n.noScheduleHere,
                            textAlign: TextAlign.center,
                            style: AppTokens.sectionTitle),
                        EmptyState(L10n.noScheduleHereHint),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 这个月是不是**一天班表都没有**（「其余时间」设成了「无」、又没有任何段覆盖）。
  ///
  /// 逐天问一遍：一个月最多 31 次，可以忽略；而判「中点那天」会在跨段边界的
  /// 月份上判错。
  ///
  /// **判据是「这天有没有班表在管」（`chain.hasScheduleOn`），不是「这天画得出什么」**。
  /// 两者在空白表（跟随法定节假日）上分家：那套班表**天天都在管**，`shiftOn` 却恒为
  /// null（它没有班次定义）。用后者就会把「只有一套法定班次」误判成空库、整张日历被
  /// 这层指路盖住 —— v0.9.14 真机反馈的正是它；v0.9.15 一度改成「给空白表合成一个
  /// 上班 / 休息班次」来绕开，那是拿**显示**去迁就**判据**，用户当即指出「确实不应该
  /// 显示上班，它本质上就是一张日历」。判据归判据、显示归显示。
  bool _computeMonthHasNoSchedule(ScheduleChain? chain) {
    final DateTime month = _month;
    if (chain == null) return true;
    final days = DateTime(month.year, month.month + 1, 0).day;
    for (var d = 1; d <= days; d++) {
      if (chain.hasScheduleOn(DateTime(month.year, month.month, d))) return false;
    }
    return true;
  }

  Widget _gridBody(
      BuildContext context, ScheduleChain? chain, double availHeight) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW = (constraints.maxWidth - _hPad * 2) / 7;
        // 行内等高：先把每行高度算出来（`_cellRect` / `_selectedRect` 读它）。
        _computeRowHeights(context, chain);
        final cellH = calendarCellHeight(
          cellW: cellW,
          // 预留 2px：cellH 按剩余空间均分算出来后，网格内容的高度就
          // **正好等于**可用高度，一行都不多 —— 真机上一旦有亚像素取整，
          // 最后一行就会被滚动容器裁掉一条。留 2px 让内容稳稳落在视口内。
          // （真正的大头是 _minCellH 曾经顶得比视口还高，见那里的说明。）
          availHeight: availHeight - 2,
          weekRows: _weekRows,
          weekdayH: _weekdayH,
          // 窄屏 / 短屏上格子可以更「瘦高」一些：格子本来就窄，再按 0.62
          // 卡住高度就装不下三行字了。竖屏不传这个参数，用的还是 0.62。
          aspectMin: (AppLayout.of(context).isNarrow ||
                  AppLayout.of(context).isShort)
              ? 0.46
              : _cellAspectMin,
        );
        final selectedRect = _selectedRect(cellW, cellH);
        final showBlock = _dragActive || selectedRect != null;
        final blockLeft = _dragActive
            ? _hPad + _visualCol * cellW
            : (selectedRect?.left ?? 0);
        final blockTop = _dragActive
            ? _visualRowToY(_visualRow)
            : (selectedRect?.top ?? 0);
        // 目标变了就起一次滑行。**必须在算 `lensCenter` 之前**：挤压场用的是
        // 「这一帧块在哪儿」，而那正是它更新出来的。
        _syncBlockFlight(
            showBlock,
            Offset(blockLeft, blockTop),
            cellW,
            _gridContentH / math.max(1, _weekRows));

        // ── 多选态那条水带（只有液态档画）────────────────────────────────
        // 长按的落点（anchor）固定不动，动的是 focus —— 往回拖时它就是**起端**。
        final DateTime? bandAnchor = _rangeAnchor;
        final DateTime? bandFocus = _rangeFocus;
        final bool bandVisible = bandAnchor != null && bandFocus != null;
        final Rect? bandTip = bandVisible ? _cellRect(bandFocus, cellW, cellH) : null;
        // ⚠️ **落点算不出来就不画**：拖选当中另一根手指点了 ‹ / ›（或点「今天」、
        // 或桌面小组件跳过来）会让 `_month` 一换 —— 那时的 `bandFocus` 就不在新月
        // 的格子里了，`_cellRect` 返回 null。少了这一条，下面那句 `bandTip!`
        // 会当场抛（独立审查抓的，用例跟着它一起写）。
        final bool showBand = bandTip != null && liquidGlassActive.value;
        // 挤字的场中心 = **淌着的末端**（还没收到第一帧回调时退回它吸附到的那一格）。
        //
        // ⚠️ `tipPos` 量的是那一端的**格边**（`k` = 第 k 格的右/左缘），所以场心要
        // **再加半格**才是那一格的中心 —— 少这半格，场会偏在格的边上，连末端自己
        // 那一格都被挤（出图上当场看得见）。
        final double bandTipCol =
            bandTip == null ? 0 : (bandTip.left - _hPad) / cellW;
        final Offset? bandWarpCenter = !showBand
            ? null
            : Offset(
                _hPad + ((_rangeTipPos ?? bandTipCol) + 0.5) * cellW,
                bandTip.center.dy);

        // 挤压场的中心：多选态跟着**会动的那一头**（水带末端），否则跟着那枚块。
        // ⚠️ 这一段跑在 `LayoutBuilder` 的**布局阶段** —— 只能静默写。
        _publishFrame(
            center: !liquidGlassActive.value
                ? null
                : showBand
                    ? bandWarpCenter
                    : (showBlock
                        ? Offset(_flightPos.dx + cellW / 2,
                            _flightPos.dy + cellH / 2)
                        : null),
            silent: true);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            setState(() {
              _pressed = true;
              _dragActive = false;
            });
            _selectFromPosition(d.localPosition, cellW, cellH);
          },
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () {},
          onPanStart: (d) {
            final rect = _selectedRect(cellW, cellH);
            double startCol, startRow;
            if (rect != null) {
              startCol = (rect.left - _hPad) / cellW;
              startRow = _yToVisualRow(rect.top);
            } else {
              startCol =
                  ((d.localPosition.dx - _hPad) / cellW).floor().toDouble();
              startRow = _yToVisualRow(d.localPosition.dy).floorToDouble();
            }
            setState(() {
              _pressed = true;
              _dragActive = true;
              _visualCol = startCol;
              _visualRow = startRow;
              _grabCol = (d.localPosition.dx - _hPad) / cellW - startCol;
              _grabRow = _yToVisualRow(d.localPosition.dy) - startRow;
              // 速度从这一格起算：上一段拖动的尾巴不许再算进来。
              _vx = 0;
              _vy = 0;
              _lastFrameStamp = null;
              _lastVelCol = startCol;
              _lastVelRow = startRow;
            });
          },
          onPanUpdate: (d) {
            final double col = (d.localPosition.dx - _hPad) / cellW - _grabCol;
            final double row = _yToVisualRow(d.localPosition.dy) - _grabRow;
            // 速度：**位置的帧间差分 ÷ 真实的帧间隔**（`lensVelocityStep`，带低通）。
            // 与底栏 / 分段器 / 开关 / 响铃那枚药丸同一套 —— **别退回 `delta × 60`**：
            // 120Hz 上每帧位移只有一半、形变也就只有一半（v0.10.6 与 v0.10.14 各踩过一次）。
            //
            // ⚠️ **只在帧戳真的变了时才算**：同一帧 rebuild 多次是常态（指针事件不按帧到达），
            // 第二遍进来位移已经被吃掉、算出来是 0，而低通会把那个 0 当真。
            final Duration stamp =
                SchedulerBinding.instance.currentSystemFrameTimeStamp;
            if (stamp != _lastFrameStamp) {
              final Duration? prev = _lastFrameStamp;
              _lastFrameStamp = stamp;
              if (prev != null) {
                _vx = lensVelocityStep(
                    deltaPage: col - _lastVelCol,
                    itemW: cellW,
                    dt: stamp - prev,
                    previous: _vx);
                _vy = lensVelocityStep(
                    deltaPage: row - _lastVelRow,
                    itemW: _gridContentH / math.max(1, _weekRows),
                    dt: stamp - prev,
                    previous: _vy);
              }
              _lastVelCol = col;
              _lastVelRow = row;
            }
            final DateTime? before = _nearestDateFromVisual();
            _visualCol = col;
            _visualRow = row;
            if (liquidGlassActive.value) {
              // 位置与速度每帧都在变 —— 走通知源，**整页不跟着重建**。
              _flightPos = Offset(_hPad + col * cellW, _visualRowToY(row));
              _publishFrame(
                  center: Offset(_flightPos.dx + cellW / 2,
                      _flightPos.dy +
                          _rowHeights[_visualRow.round().clamp(
                                  0, _rowHeights.length - 1)] /
                              2));
              // **吸附到的那一格真的变了才重建整页**：那一格的班次胶囊要画成实心，
              // 而那是「标题级」的状态。与 `onLongPressMoveUpdate` 同一条纪律
              // —— 每帧重建整页正是这一轮要消掉的东西。
              if (_nearestDateFromVisual() != before) setState(() {});
            } else {
              // 标准档那棵树一个字不改：它的位置由 `AnimatedPositioned` 自己走，
              // 而那个位置是从布局里的 `_visualCol/_visualRow` 算出来的。
              setState(() {});
            }
          },
          onPanEnd: (_) {
            final date = _nearestDateFromVisual();
            // 与 `_selectFromPosition` 同一口径：**吸附到的格子真的变了**才震。
            // 快甩（100ms 内就超过 slop）这一路 `onTapDown` 从来没响过 ——
            // 竞技场里 Pan 先赢、Tap 直接被判负，所以「拖到新的一格」的触觉
            // 只有这儿发得出来；慢按起手那一下则由 `_selectFromPosition` 负责。
            // `changed` 要先取：下面 `setState` 会把 `_selected` 改成 `date`。
            final changed = date != null && date != _selected;
            setState(() {
              _pressed = false;
              _dragActive = false;
              if (date != null) _selected = date;
              // ⚠️ **不要把 `_vx` / `_vy` 归零**：松手之后那枚块还要靠最后一次速度
              // 把形变**收回去**（`CalendarLens` 自己按帧衰减）。归零的话形变会
              // 「啪」地消失，而不是收回去。下一次 `onPanStart` 才清它。
            });
            if (changed) Haptics.select();
          },
          // 长按拖选：按住不动约 500ms 长按赢，立刻滑动仍然是上面的 Pan 赢 ——
          // 两套手势在竞技场里天然分流，互不顶掉（`_pressed` / `_dragActive` 是
          // 两套状态，长按起手时要把滑块那套先熄掉，免得玻璃块跟长按同时亮）。
          onLongPressStart: (d) {
            // 空白表方案（跟随法定节假日）没有班次定义可挑，长按不该进入范围态
            // （spec §7.3）—— 否则用户拖出一片淡染、松手却什么也不发生。判据
            // 与信息卡入口、`adjustDays` 内部那一处同源。
            //
            // 整条链上有一套「有周期」的就能进 —— 具体那天归哪套、能不能挑，
            // 由 `adjustDays` 按起点那天再判一次。
            final canPick = chain?.hasCycle ?? false;
            final date =
                canPick ? _dateFromPosition(d.localPosition, cellW, cellH) : null;
            setState(() {
              // 长按赢下竞技场之后 `onTapUp` / `onPanEnd` 都不会再来，滑块那套
              // 状态必须在这儿熄掉 —— 不然玻璃块停在按下的放大态，或者跟范围
              // 淡染一起亮。落在本月之外的空白格时 `date` 是 null，范围态因此
              // 保持为空（后续 moveUpdate / end 都空转），但这一下同样要把上面
              // 那两个标志清掉。
              _pressed = false;
              _dragActive = false;
              _rangeAnchor = date;
              _rangeFocus = date;
              // 上一段拖选留下的末端位置不许漏到这一段来（场会先歪一帧）。
              _rangeTipPos = null;
            });
            // 进入多选态那一下**更明显**，好跟后面每进一格的轻震分开（spec §4.3）。
            // 放在 `setState` 之外：它的回调必须同步且无副作用，触觉是副作用。
            //
            // 但**没进入多选态就不许响**：长按落在空白格 / 周标题上，或整张空白表
            // 方案（`canPick` 为假，spec §7.3）时 `date` 是 null、`_rangeAnchor`
            // 也没设上 —— 那一下什么也没发生，却发一记「进入多选态」的强震，
            // 正是这套设计要避免的「震了却不携带信息」。
            if (date != null) Haptics.modeEnter();
          },
          onLongPressMoveUpdate: (d) {
            if (_rangeAnchor == null) return;
            final date = _dateFromPosition(d.localPosition, cellW, cellH);
            if (date == null || date == _rangeFocus) return;
            // 吸附到的格子真的变了才震 —— 原地抖一下不响；范围往回缩时同样会响，
            // 两个方向一致（spec §4.3）。
            Haptics.select();
            setState(() => _rangeFocus = date);
          },
          onLongPressEnd: (_) {
            final from = _rangeAnchor;
            final to = _rangeFocus;
            setState(() {
              _rangeAnchor = null;
              _rangeFocus = null;
            });
            if (from == null || to == null) return;
            // 起点终点谁在前都行，调换成正序 —— `adjustDays` 不认 `from > to`，
            // 传反了它会静默拼出空列表、弹一条误导的提示。
            final a = daysBetween(from, to) >= 0 ? from : to;
            final b = daysBetween(from, to) >= 0 ? to : from;
            adjustDays(a, b);
          },
          // 手指被系统取消（切前台、来电 —— 网格外面就是滚动容器）：
          // `onLongPressEnd` 只在 `PointerUp` 时发，取消只有这一条回调。
          // 注意长按赢下竞技场之后它**照样**会发：`GestureRecognizerState`
          // 只有 ready/possible/defunct 三档，accept 不改 state，所以
          // `_checkLongPressCancel` 的 `state == possible` 仍然成立。
          onLongPressCancel: _clearGestureState,
          child: ClipRect(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _hPad),
                  child: Column(
                    children: [
                      _weekdayRow(context, cellW),
                      ..._dayRows(context, cellW, cellH, chain),
                    ],
                  ),
                ),
                // 水带画在**网格之上、那枚块之下**：它是一层（逐格淡染盖不住格与格之间
                // 那 4px 的缝），而那枚「今天/选中的一天」始终压在最上面。
                if (showBand)
                  Positioned.fill(
                    child: CalendarRangeBand(
                      size: Size(2 * _hPad + 7 * cellW, _gridContentH),
                      cellW: cellW,
                      cellH: cellH,
                      hPad: _hPad,
                      weekdayH: _weekdayH,
                      rowHeights: _rowHeights,
                      runs: rangeRowRuns(
                          from: bandAnchor!, to: bandFocus!, month: _month),
                      movingEnd: daysBetween(bandAnchor, bandFocus) >= 0,
                      tipCell: ((bandTip.left - _hPad) / cellW).round(),
                      accent: Theme.of(context).colorScheme.primary,
                      isDark: Theme.of(context).brightness == Brightness.dark,
                      // 末端淌到哪儿了。**走通知源，不是 `setState`** —— 带子在动的
                      // 时候这个回调是**每帧**发的，`setState` 就等于每帧把整页重建
                      // 一遍（独立审查实测 509 个 widget/帧，比滑行那条路还狠）。
                      //
                      // 场心仍然跟着「淌着的那一点」（规格 §4.5 那条订正：不能跟
                      // 「末端吸附到的那一格」，格心的权重恒为 0，那样一格都不挤）。
                      onTipPos: (double v) {
                        if (!mounted) return;
                        _rangeTipPos = v; // 真值照记（布局那一份也读它当兜底）
                        _publishFrame(
                            center: Offset(_hPad + (v + 0.5) * cellW,
                                bandTip.center.dy));
                      },
                    ),
                  ),
                if (showBlock)
                  _blockPlacement(
                      context,
                      cellW,
                      // 块高 = **目标行的实际行高**（行内等高下每行不同，用均分的
                      // cellH 会让块中心偏离该格中心 —— 真机拖拽测试抓到的）。
                      _dragActive
                          ? _rowHeights[_visualRow.round().clamp(
                              0, _rowHeights.length - 1)]
                          : (_selectedRect(cellW, cellH)?.height ?? cellH),
                      blockLeft,
                      blockTop),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 周标题行。
  ///
  /// 每个标签**包一层 `FittedBox(scaleDown)`**：`_weekdayH` 是个固定常数（26），
  /// 而这一行的字号是 `labelSecondary` **再乘系统字号** —— 系统字号放到 2×，字高
  /// 约 30dp 就顶出这条 26dp 的带了，`Center` 不裁也不省略，于是这行字**压进下面
  /// 第一行格子里**（2026-09-29 用户截图里那行看着「挤」的就是它）。
  ///
  /// **有意不去按系统字号长高 `_weekdayH`**：那个常量同时被 `_buildGrid` 的命中
  /// 测试算式用（`d.localPosition.dy - _weekdayH`，六处），改成逐帧算的值要让那些
  /// 算式一起跟着走 —— 漏一处就是「系统字号调大之后点哪一格都不对」。而且换来的
  /// 高度换不成更大的字：格子里的字是按**格子高度**缩放的，网格本身是定尺的。
  ///
  /// 这条与整格那层 `FittedBox` 是同一条设计规则：**网格是定尺的点阵，字一律归一到
  /// 格子里**；真正按系统字号长的是底栏信息卡（`info_card_metrics.dart` 用
  /// `textScaler` 实测高度）。
  Widget _weekdayRow(BuildContext context, double cellW) {
    final labels = L10n.weekdays;
    return SizedBox(
      height: _weekdayH,
      child: Row(
        children: List.generate(7, (i) => SizedBox(
              width: cellW,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    labels[i],
                    style: AppTokens.labelSecondary
                        .copyWith(color: AppTokens.inkMuted(context)),
                  ),
                ),
              ),
            )),
      ),
    );
  }

  /// 算当月每行高度（行内等高：该行最多几个胶囊就多高），并写 [_rowHeights]。
  ///
  /// 必须在 `_gridBody` 的 `_selectedRect` **之前**跑 —— `_cellRect` 读
  /// `_rowHeights`，那会儿要是空的（`const []`）就当场越界。
  List<double> _computeRowHeights(BuildContext context, ScheduleChain? chain) {
    // 字号档位（0.9 / 1.0 / 1.1 / 1.2）直接放大行高里的字相关部分 ——
    // 特大档下格子内容变高，行高跟不上就 bottom overflow（真机测出来的）。
    final ts = MediaQuery.textScalerOf(context).scale(1.0);
    final dateH = 15 * ts;
    final chipH = 18 * ts;
    final chipGap = ts;
    final tagH = 13 * ts;
    final inset = 4.0;
    // 先把当月每天的胶囊数（= 全部班次的所有时段段数）算出来，用于行内等高。
    // 参考图样式：一天几个时段就几个胶囊，行高按**该行最多那天**定。
    final cellShiftCounts = <int>[];
    for (var d = 1; d <= _daysInMonth; d++) {
      final date = DateTime(_month.year, _month.month, d);
      final shifts = chain?.shiftOn(date) ?? const [];
      cellShiftCounts.add(
          shifts.fold(0, (n, s) => n + s.allSegments.length));
    }

    // 每行最大胶囊数（含月初空格按 0 计）。
    final rowMaxShifts = <int>[];
    for (var r = 0; r < _weekRows; r++) {
      var max = 0;
      for (var c = 0; c < 7; c++) {
        final idx = r * 7 + c - _leading;
        if (idx >= 0 && idx < _daysInMonth) {
          max = math.max(max, cellShiftCounts[idx]);
        }
      }
      rowMaxShifts.add(max);
    }

    // 每行高度 = 日期行 + 标签行（可无）+ 该行最多胶囊数 × 单胶囊高 + 间隔。
    // 基准是**内容自然高**（不再是旧设计的 `_minCellH` —— 那 58 是三行字的下限，
    // 新格子只有「日期 + 胶囊」两行，58 会把小窗格子顶出视口）：
    // 日期 `cellDateSm` 13×1.15 ≈ 15 + 间隔 2 + 胶囊 `microStrong` 12×1.15 ≈ 14
    // + 上下 padding 2×2 = 18，每个额外胶囊 + 18 + 1；再加内缩上下各 2。
    // 该行只要有一天是节假日 / 调休（标签在日期与胶囊之间出现），整行都要给
    // 标签行让位 + 2 + 13 —— 行内等高要求同行同高，差出来就 bottom overflow。
    final rowHeights = <double>[];
    for (var r = 0; r < _weekRows; r++) {
      final count = rowMaxShifts[r];
      var hasTag = false;
      for (var c = 0; c < 7; c++) {
        final idx = r * 7 + c - _leading;
        if (idx >= 0 && idx < _daysInMonth) {
          final d = DateTime(_month.year, _month.month, idx + 1);
          final lunar = lunarOf(d);
          if (lunar.isLegalHoliday || lunar.isMakeupWorkday) {
            hasTag = true;
            break;
          }
        }
      }
      final base = (dateH +
              2 * ts +
              (count > 0 ? count * chipH + (count - 1) * chipGap : 0) +
              (hasTag ? 2 * ts + tagH : 0) +
              inset +
              10) // 呼吸余量：字号 / 行高在部分设备上会略微超估（曾 6，360dp small 档差 0.18px）。
          .toDouble();
      // 兜底：连日期都装不下的极端小窗（200 宽）给个下限。
      rowHeights.add(math.max(base, 30));
    }
    _rowHeights = rowHeights;
    return rowHeights;
  }

  List<Widget> _dayRows(BuildContext context, double cellW, double cellH,
      ScheduleChain? chain) {
    // 比「同一天」用 `isSameDay` 而不是 `==`：`dateOnly` 是 UTC 日期、这里的
    // `date` 是本地日期，`DateTime.==` 连 `isUtc` 一起比，`==` 恒为假
    // （「今天」的日期因此一直没加粗过）。
    final now = DateTime.now();
    final today = dateOnly(now);
    final rowHeights = _computeRowHeights(context, chain);

    final cells = <Widget>[];
    for (var i = 0; i < _leading; i++) {
      cells.add(SizedBox(width: cellW, height: rowHeights[0]));
    }
    for (var d = 1; d <= _daysInMonth; d++) {
      final date = DateTime(_month.year, _month.month, d);
      final row = (d - 1 + _leading) ~/ 7;
      final shifts = chain?.shiftOn(date) ?? const [];
      cells.add(_dayCell(
          context,
          date,
          shifts,
          lunarOf(date),
          cellW,
          rowHeights[row],
          isSameDay(date, today),
          chain?.scheduleOn(date)?.dayOverrides.containsKey(dayNumber(date)) ??
              false,
          // 逐格那层 14% 淡染：**液态档由那条带子取代**（标准档一个字没改）。
          !liquidGlassActive.value &&
              _rangeAnchor != null &&
              _rangeFocus != null &&
              _inSelectedRange(date),
          now: now,
          // 用户选 C = 日历格子**不参考液态档**，恒传 null ⇒ `LensWarpScope` 不挂。
          warpCenter: null));
    }
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      final chunk = cells.sublist(i, math.min(i + 7, cells.length));
      rows.add(Row(children: chunk));
    }
    return rows;
  }

  /// 磨砂卡片日期格（v0.14 重写：参考图样式）。
  ///
  /// 排布：日期 + 节假日/调休小标签（可选）+ **实心时段胶囊列表**。
  /// 每个班次的每个时段段一个胶囊，文本 = 时段（`6-8` / `22-0`，见 [ShiftSegment.cellLabel]）。
  ///
  /// 从格子里移走的内容（农历、倒计时、首末时段、班次名）进了底部信息卡 ——
  /// 格子回答「哪天上什么班（几点）」，卡片回答「还有什么细节」。
  ///
  /// 时间远近用**胶囊深浅**表达（参考图「灰 = 已过期 / 蓝 = 未结束」）：
  /// 已结束的时段胶囊降透明度（变淡），未结束的保持实色。今天与未来都是实色。
  ///
  /// 格子里的字不再按格子高度等比缩放（[AppTokens.scaled] 已不用于胶囊）：
  /// 行高由胶囊数决定，字是固定小字号，装不下的胶囊由 FittedBox 兜底。
  ///
  /// [adjusted] 表示这天被「按天改班」覆盖过，右上角点一个小圆点。
  /// [inRange] 表示这天落在长按拖选的范围里，整格铺一层主色淡染。
  ///
  /// [now] 是当前时间，用于胶囊深浅编码（已过期 vs 未结束）。
  ///
  /// [warp] 是液态档那枚透镜把它**内容**挤了一下的仿射变换（`null` = 不套）。
  /// 只套内容、**不套卡片**：卡片动了就成了「格子自己在扭」，而用户要的是
  /// 「一枚玻璃压过去」。`Transform` 只改绘制、不改布局，所以字的排版不会跟着变。
  Widget _dayCell(BuildContext context, DateTime date, List<ShiftClass> shifts,
      LunarInfo lunar, double cellW, double cellH, bool isToday,
      bool adjusted, bool inRange,
      {required DateTime now, Offset? warpCenter}) {
    final primary = Theme.of(context).colorScheme.primary;
    final contentW = cellW - _cellInset * 2;

    // 第 1 行：日期 + 节假日/调休小标签（同排）。今天 = 主色加粗（参考图：蓝色加粗）。
    // 标签跟日期同一行，不占独立行 —— 否则有标签的格子胶囊起点比无标签的低
    // （上一轮用户反馈对齐），而叠在日期上方又会重叠（这轮反馈）。
    final dateStyle = AppTokens.cellDateSm.copyWith(
      fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
      color: isToday ? primary : Theme.of(context).colorScheme.onSurface,
      height: 1.15,
    );
    final Widget? tagChip = lunar.isLegalHoliday || lunar.isMakeupWorkday
        ? Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceXs, vertical: 1),
            decoration: BoxDecoration(
              color: (lunar.isLegalHoliday ? AppTokens.holiday : Colors.orange.shade700)
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTokens.radiusS),
            ),
            child: Text(
              lunar.isLegalHoliday ? L10n.holidayTag : L10n.makeupTag,
              maxLines: 1,
              style: AppTokens.tinyLabel.copyWith(
                color: lunar.isLegalHoliday
                    ? AppTokens.holiday
                    : Colors.orange.shade700,
                fontWeight: FontWeight.w700),
            ),
          )
        : null;
    final dateLine = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${date.day}', maxLines: 1, style: dateStyle),
          if (tagChip != null) ...[const SizedBox(width: AppTokens.gapHair), tagChip],
        ],
      ),
    );

    // 第 3 行（可多行）：实心时段胶囊。每个时段一个，**按开始时间从小到大排**
    // （用户 2026-10-25 反馈：22-0 不该排在最前）。跨午夜时段按它的
    // startMinute（22:00=1320）插到正常位置，不特殊处理。
    final nowMinute = now.hour * 60 + now.minute;
    final coloredSegs = <({ShiftSegment seg, Color color})>[
      for (final shift in shifts)
        for (final seg in shift.allSegments) (seg: seg, color: Color(shift.color)),
    ]..sort((a, b) => a.seg.startMinute.compareTo(b.seg.startMinute));
    final chips = <Widget>[];
    for (var i = 0; i < coloredSegs.length; i++) {
      final seg = coloredSegs[i].seg;
      final color = coloredSegs[i].color;
      // 已结束的时段：降透明度（参考图「灰 = 已过去」），未结束保持实色。
      final ended = seg.endMinute <= nowMinute;
      final chipColor =
          ended ? color.withValues(alpha: 0.35) : color;
      chips.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Container(
          key: ValueKey('day-chip-${date.day}-$i'),
            alignment: Alignment.center,
            width: contentW,
            padding: const EdgeInsets.symmetric(
                vertical: AppTokens.padChipV, horizontal: AppTokens.spaceXs),
            decoration: BoxDecoration(
              color: chipColor,
              borderRadius: BorderRadius.circular(AppTokens.radiusS),
            ),
            // Text 在无界约束下自然宽，FittedBox 缩到胶囊内 ——
            // 窄格子（360dp 小窗）里「18-22」这类 5 字符不会截成省略号。
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                seg.cellLabel,
                maxLines: 1,
                style: AppTokens.microStrong.copyWith(
                    color: Colors.white, height: 1.15),
              ),
            ),
          ),
        ));
    }

    // 内容那一层：日期 → 标签 → 胶囊列表（居中列）。
    final children = <Widget>[
      dateLine,
      if (chips.isNotEmpty) ...[const SizedBox(height: AppTokens.gapHair), ...chips],
    ];
    final Widget fittedContent = Column(
      mainAxisSize: MainAxisSize.min,
      // 日期贴顶（参考图）：日期在格子顶部，胶囊往下排，多余空间留底部。
      // 否则胶囊多的格子内容变高、日期被推到不同位置（用户 2026-10-25 反馈）。
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );

    return SizedBox(
      width: cellW,
      height: cellH,
      child: Container(
        key: ValueKey('day-card-${date.day}'),
        margin: const EdgeInsets.all(_cellInset),
        decoration: _cardDecoration(context),
        child: Stack(
          children: [
            if (inRange)
              Positioned.fill(
                child: DecoratedBox(
                  key: ValueKey('day-range-${date.day}'),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.14),
                    borderRadius: _cellRadius,
                  ),
                ),
              ),
            // 右上角的「已调班」小圆点：挂在格子右上角。
            if (adjusted && shifts.isNotEmpty)
              Positioned(
                right: -2,
                top: -2,
                child: _cornerDot(
                    key: ValueKey('day-adjusted-${date.day}'),
                    color: Color(shifts.first.color)),
              ),
            Positioned.fill(
              child: warpCenter == null
                  ? fittedContent
                  : LensWarpScope(
                      center: _lensCenter,
                      cellCenter: warpCenter,
                      cellW: cellW,
                      cellH: cellH,
                      inset: _cellInset,
                      child: fittedContent,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 今天格的倒计时文本：距下一段岗次开始还有多久。
  ///
  /// 首末时段标签已删：时段胶囊每个段一格，文本由 [ShiftSegment.cellLabel] 给出。
  /// 倒计时已移到今日信息卡（v0.14）。

  BoxDecoration _cardDecoration(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.white.withValues(alpha: 0.92),
      borderRadius: _cellRadius,
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.black.withValues(alpha: 0.06),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  /// 那枚块**摆在哪儿**。两档各一棵树：
  ///
  /// · **标准档**：`AnimatedPositioned` 自己走 —— 那棵树**一个字节都没动**。
  /// · **液态档**：位置由我们算（`_flightPos`），因为滑行时的速度与挤压场都要那个
  ///   中间位置，而 `AnimatedPositioned` 不把它交出来（见 `_syncBlockFlight`）。
  ///
  /// 两棵树用**同一套曲线与时长**（`_blockSlideCurve` / `_blockSlideDuration`），
  /// 所以两档飞起来一样快、一样刹车。
  Widget _blockPlacement(BuildContext context, double cellW, double cellH,
      double left, double top) {
    if (liquidGlassActive.value) {
      // 位置每帧都在变 —— 走通知源，**整页不跟着重建**。
      //
      // ⚠️ **`Stack` 的孩子必须是 `Positioned`**：`FrameBuilder` 直接塞进去会让那
      // 一块变成「非定位孩子」，布局当场错。所以外面套 `Positioned.fill`，由 builder
      // 返回的**内层 `Stack`**（`clipBehavior: Clip.none`，让透镜照旧能鼓到格子外）
      // 去摆那个真的 `Positioned`。外层那个 Stack 的裁剪行为因此与今天一字不差。
      return Positioned.fill(
        child: FrameBuilder<BlockFrame>(
          listenable: _blockFrame,
          builder: (BuildContext context, BlockFrame f, Widget? _) => Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: f.pos.dx,
                top: f.pos.dy,
                width: cellW,
                height: cellH,
                // ⚠️ **透镜本体必须在这里现建**（不能在 builder 外面建好再传进来）：
                // 它每帧要一个新速度（`_blockFrame.value` 刚写进去的那一份），而同一个
                // widget **实例**是不会被重建的 —— 建在外面等于把它冻在第一帧的速度上
                // （v0.10.17 那条「滑行中彩边亮起来」的用例当场抓到过）。
                child: AnimatedScale(
                  // ⚠️ 液态档**钉在 1.0**：按住那个动作改由「四面鼓出 + 浮起阴影」
                  // 承担（`CalendarLens` 的升程），两个叠在一起就重了。
                  scale: 1.0,
                  duration: AppTokens.durMed,
                  curve: Curves.easeOutBack,
                  child: _glassBlock(context, cellW, cellH),
                ),
              ),
            ],
          ),
        ),
      );
    }
    // 标准档：位置由 `AnimatedPositioned` 自己走，**那棵树一个字不改**
    // （`scale` 仍是 `_pressed` 那 1.22）。
    return AnimatedPositioned(
      duration: _dragActive ? Duration.zero : _blockSlideDuration,
      curve: _blockSlideCurve,
      left: left,
      top: top,
      width: cellW,
      height: cellH,
      child: AnimatedScale(
        scale: _pressed ? 1.22 : 1.0,
        duration: AppTokens.durMed,
        curve: Curves.easeOutBack,
        child: _glassBlock(context, cellW, cellH),
      ),
    );
  }

  /// 可拖拽的玻璃选择块（与格子同 inset、同圆角，精确覆盖）。
  Widget _glassBlock(BuildContext context, double cellW, double cellH) {
    final accent = Theme.of(context).colorScheme.primary;
    // 液态档：一枚真的玻璃透镜（按住四面鼓出、拖动跟速度形变、边缘挤过格子里的字）。
    // 它替下的是那个 1.22 的等比放大 —— 标准档那棵树上那条路径一个字没动。
    if (liquidGlassActive.value) {
      return CalendarLens(
        // 与标准档那一枚**同一个 key**：它就是「选中块」这一个东西，
        // 两个档位各是一棵树，但对外（单测、工装）是同一个身份。
        key: const Key('calendar-selection-block'),
        size: Size(cellW, cellH),
        liftTarget: (_pressed || _dragActive) ? 1 : 0,
        // 速度的**两条来路**都从这一个入口进去：手指在拖（`onPanUpdate` 的帧间
        // 差分），以及那枚块自己在滑行（`_onFlightTick` 算的）。两处都是每帧一个新
        // 采样，所以 `CalendarLens` 那边那条「别把陈旧的值反复灌回来」照样成立。
        // 这两个值每帧都在变，从通知源现读（`_publishFrame` 刚写进去的那一份）。
        velocityLive: _blockFrame.value.live,
        velocity: _blockFrame.value.velocity,
        isDark: Theme.of(context).brightness == Brightness.dark,
        accent: accent,
      );
    }
    return Container(
      key: const Key('calendar-selection-block'),
      margin: const EdgeInsets.all(_cellInset),
      decoration: BoxDecoration(
        borderRadius: _cellRadius,
        // 14% 是全 app 的淡染约定值。这里从前是 13% —— 拖动选范围时
        // 范围底色（14%）会紧贴这一块，两个值同屏只显得脏。
        color: accent.withValues(alpha: 0.14),
        border: Border.all(color: accent, width: 2),
        // **没有 boxShadow**，这是有意的，别加回来。
        //
        // 这一层画在网格**之上**（Stack 的后一个 child），所以它必须是半透明的
        // —— 不透明就把选中那格的日期、班次胶囊、农历全糊掉了（试过，格子直接
        // 变空）。而正因为它是半透明的，一旦有 `boxShadow`（主色 25%），阴影就会
        // 从块**内部**透出来再叠一层：格子内部实际吃到约 33% 的主色，而不是
        // 设计要的 13%。
        //
        // 后果是选中那格的**实心班次胶囊被洗掉色相**：橙 `#FF9F0A` 洗成棕
        // `#C28758`，蓝 `#4C8DFF` 会和主色块糊成一片。而「选中那格的班次最抢眼」
        // 正是实心胶囊的全部意义。
        //
        // 想在块外留光晕也不行：阴影只能画在内容之上，才会被看得见；画在内容
        // 之下就会被格子自身近乎不透明的卡片底（白 92%）盖住。所以这里二选一，
        // 选保住胶囊的色相 —— 「选中」这个信号由 2px 主色描边 + 13% 淡染承担，
        // 它们本来就扛得住。
      ),
    );
  }

}

/// 格子角上那个小圆点（右上 = 这天调过班，左上 = 这个班挂了闹钟）。
///
/// spec §7.4：**固定在 3–4dp、不跟格子高度缩放** —— 格子里的字是按格子高等比
/// 缩放的，小窗里缩到 1–2px 就等于没有。这里借间距刻度上的 4dp 一档
/// （`spaceXs`）：光学刻度（`gapHair` / `padChipV` …）最高的 3dp 也在区间内，
/// 但它们表达的是「控件内部两个元素贴合的微距」，用在标记的**尺寸**上语义不对。
Widget _cornerDot({required Key key, required Color color}) => Container(
      key: key,
      width: AppTokens.spaceXs,
      height: AppTokens.spaceXs,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

/// 「这个班次挂没挂联动闹钟」与「那一行怎么写」已经搬到 `domain/day_summary.dart`
/// （`shiftHasAlarms` / `alarmNote`）—— 桌面小组件的今日卡要用**同一份**，
/// 两处各写一遍必然分岔，而分岔时不报错。
///
/// 信息卡（完整版）在**底栏**时的高度不再是写死的常数，改成按当前月最满的
/// 一天算出来 —— 实现在 `info_card_metrics.dart`，那里写了为什么。
///
/// 这里只留一条约束给下游：**高度必须与「选中哪天」无关**。竖屏下这一页是
/// `Column[顶栏, Expanded(网格), 信息卡]`，格子高度按**剩余空间**算
/// （`calendarCellHeight(availHeight:)`），卡片只要随当天内容长高一像素，
/// 六个格子就集体矮一像素、选下一天再弹回来 —— 点一天晃一次。
///
/// 也不能反过来把网格与卡片解耦（留白、或让网格自己滚动）：v0.6.1 刚把
/// 「网格与信息卡之间的一条空带」消掉，那条空带是明确不接受的。所以卡片
/// 始终撑满自己的盒子，多出来的空间留在卡片内部 —— 它是一块面板，不是一条
/// 会伸缩的条。
///
/// 高度算得准不准由 `calendar_screen_test.dart` 的「点开某天」用例盯着：它把
/// 整月每一天都点一遍，断言高度不变、内容装得下、且贴得够紧。

// 格子高宽比：0.78 = 自然比例，0.62 = 「不许再瘦」的下限比例（越小格子越高）。
const double _cellAspect = 0.78;
const double _cellAspectMin = 0.62;

/// 格子字号的缩放上限。再大就喧宾夺主：格子被字填满、格子之间的呼吸感没了。
/// 1.25 是 v0.7.2 从 1.35 调下来的（配合 `cellShift` 15→13），单字胶囊的字号
/// 上限从 20.25 降到 16.25。
///
/// **这条判断只在手机上成立** —— 宽屏档另有一档，见 [_cellMaxScaleWide]。
const double _cellMaxScale = 1.25;

/// 宽屏档（`AppLayout.isWide`）的格子字号上限。
///
/// **为什么宽屏要放开**：格子内容按 `(cellH − 内缩) / _cellDesignH(55)` 等比缩放、
/// 再夹上限。车机上 cellH ≈ 90~120，`(104 − 12) / 55 ≈ 1.67` —— 1.25 那道天花板
/// 早就顶到了，于是「调大字号 / 屏幕更大」都不再让字变大（用户 2026-10-13 报的
/// 第 5 条：字号调到特大，日历界面看着还是小）。1.7 让内容占到格子的约 78%，
/// 仍有呼吸。
///
/// **判据取 `isWide` 而不是 `isWideLandscape`**：宽且矮那一支格子只有 41dp 高，
/// 上限根本不生效，多一个分支只是多一处要维护的东西。
///
/// ⚠️ **这是起手值**（照 1920×720 上 cellH≈90 反推的），出图之后可能还要回来调。
const double _cellMaxScaleWide = 1.7;

/// 格子内容的缩放上限，按档位取（见上面两个常量的说明）。
///
/// 抽成顶层纯函数（公开）是为了能直接断言「按档位分叉」——
/// 与 [calendarCellHeight] 同一个理由。
double cellMaxScale(AppLayout layout) =>
    layout.isWide ? _cellMaxScaleWide : _cellMaxScale;

/// 格子高的下限 = **格子里的三行字实测要多高**。
///
/// 不画胶囊的那一支（无班次方案、小窗）是日期 `cellDateSm` 13 + `gapHair` 2 +
/// 班次简称 `microStrong` 12 + `gapHair` 2 + 农历 `tinyLabel` 11，三者都自带
/// `height: 1.15` 压过行盒：≈ 45.4，再加格子自身 `_cellInset` 上下各 2 一共 4
/// —— 约 49.4，稳稳落在 58 之内。
///
/// 画胶囊那一支高一些（内容 ≈ 54.6、加内缩约 58.6），**正好贴着这道下限**：
/// 多出来的零点几像素由 `_dayCell` 那层 `FittedBox` 按需缩掉，肉眼看不出来，
/// 所以这里不为它抬低下限。
///
/// **曾经是 80**，那是 `height: 1.15` 压行盒之前按 M3 默认行高 1.5 标定的
/// （27 + 2 + 18 + 2 + 16.5 + 4 ≈ 70，再垫到 80）。行盒压紧后这个数一直没
/// 跟着降，于是下限反过来把**网格**顶出了视口：400×869 的手机上网格视口
/// 只有 405dp，五行的月份被顶到 26+5×80=426（溢出 21dp）、六行的顶到 506
/// （溢出 101dp），最后一行被 `SingleChildScrollView` 裁在信息卡上沿 ——
/// 用户看到的就是「最后一行被卡片压住」（v0.6.5 实测）。
///
/// 下限只该管「三行字装不装得下」，不管别的；把它抬到内容需求之上，就等于
/// 让网格自己制造溢出。真正的兜底是外层那个滚动容器：空间确实不够时滚动，
/// 而不是把每一格都撑破视口。
///
/// 字号被系统放大时格子**不会**跟着长高，那是 `_dayCell` 里那层
/// `FittedBox` 的事 —— 内容按需缩，不由这个下限兜。
const double _minCellH = 58;

/// 日历格子高度：**宽高共同决定**。
///
/// 抽成顶层纯函数是为了能直接断言「横屏进入压缩分支」——
/// `SingleChildScrollView` 的尺寸是它的视口（等于可用高度），不是内容高度，
/// 拿它测不出压缩。
///
/// 空间富余时拉高，但不超过 [_cellAspectMin] 那道「不许再瘦」的比例；
/// 空间不足时**压缩到够用**，但不低于可读下限。
///
/// 原来空间不足时直接取 `cellW / _cellAspect`（只按宽度算）：横屏下 cellW 大
/// → 格子高 160 → 一个月六行要 960px，一屏只看得到一行多。那道「不许再瘦」
/// 的下限只在富余时生效、不足时反而没有任何压缩通道，逻辑正好反了。
///
/// [_minCellH] 那道下限**必须作用在最终值上**，不能只挂在其中一个分支里。
/// 宽屏上 `cellW / aspectMin` 大，走富余分支不会低于下限；窄屏（小窗 200 宽
/// 时 cellW ≈ 25）上它只有 54，于是富余分支返回一个**比格子里的三行字还矮**
/// 的高度 —— 每个格子都会 BOTTOM OVERFLOWED。下限是「装不下三行字」这件事
/// 决定的，跟走哪个分支无关。
double calendarCellHeight({
  required double cellW,
  required double availHeight,
  required int weekRows,
  required double weekdayH,
  double aspectMin = _cellAspectMin,
}) {
  final naturalCellH = cellW / _cellAspect;
  final fillCellH = (availHeight - weekdayH) / weekRows;
  final shrunk = fillCellH >= naturalCellH
      ? math.min(fillCellH, cellW / aspectMin)
      : fillCellH;
  return math.max(shrunk, _minCellH);
}

/// 换月动画里的一「页」（网格，或年月胶囊里那几个字），带着**它自己那个月**。
///
/// 带月份只为一件事：`_monthSlide` 的 `transitionBuilder` 一次拿到两个孩子 —— 进来
/// 的新月份、出去的旧月份 —— 而两者的滑动方向相反（进来的从翻页那一侧滑入，出去的
/// 往另一侧滑走）。`AnimatedSwitcher` 给两个孩子的 `animation` 是同一个（一个正向、
/// 一个反向），`animation` 本身分不出谁是谁，让每个孩子自己带上月份就分得清了。
/// 换月转场里**每帧**回调一次 —— 好让「换月」也能算进「有没有东西在动」。
///
/// 存在的理由：`AnimatedSwitcher` 的 `transitionBuilder` 只在 **build** 时跑一次，而
/// 转场里用的是同一个 `_MonthPane` 实例（子树不重建），所以父层拿不到「动画还在跑」
/// 这件事。而 `AnimatedBuilder` 会跟着 `animation` 每帧重建 —— 这就是那个信号。
///
/// ⚠️ 回调写在 **build 里**是安全的：它落到 [CalendarScreen] 的 `_markInteracting`，
/// 而那一处只写一个 `ValueNotifier`（监听者只起停 `Timer`、不 `setState`）——
/// 与 `_gridBody` 那个布局阶段的 `publishSilently` 同一条理由。
/// ⚠️ `animation.isCompleted` 之后不再回调，光晕才恢复得起来。
class _MonthRollWatcher extends StatelessWidget {
  const _MonthRollWatcher({
    required this.animation,
    required this.onFrame,
    required this.child,
  });

  final Animation<double> animation;
  final VoidCallback onFrame;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? child) {
        if (!animation.isCompleted) onFrame();
        return child!;
      },
      child: child,
    );
  }
}

class _MonthPane extends StatelessWidget {
  const _MonthPane({super.key, required this.month, required this.child});

  final DateTime month;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

