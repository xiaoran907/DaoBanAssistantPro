---
status: pending
task: 日历格子重做（参考图样式）：实心时段胶囊 + 行内等高 + 恢复今日信息卡，v0.14.1+182
slug: v014-calendar-cell
started: 2026-10-25T10:45:00Z
updated: 2026-10-25T14:05:00Z
status: done
next: 无 —— 任务完成。v0.14.1 是测试版（Z≠0），按 AGENTS 规则只留 beta 分支，不合并 main、不打 tag（main 停 0.13.0 状态）。后续发正式版 0.14.0 时再归纳 beta 提交
---

# 目标
按参考图（`1000068852-5.jpg`）重做日历格子：格子里只留「日期 + 时段胶囊」（实心班次色 + 白字 + 6-8 式时间，深浅编码时间远近），行内等高 + 内容自适应；农历/倒计时/已调班/节假日/班次名移到新增的「今日信息卡」（选中哪天讲哪天）。版本 0.14.1+182。

# 已完成
- [x] 决策盘问 12 条（docs/decisions-calendar-cell.md）：实心胶囊+自适应、保留班次颜色与农历、时间段无冒号、行内等高、格子里三个小标记（节假日/调休标签、已调班点、今天选中框）、信息卡新增（0.13.0 删过）、导航栏不改
- [x] 时段格式纯函数 `ShiftSegment.cellLabel`（无前导零、跨午夜写钟面）+ 单测 33/33（shift_rotation_test）
- [x] `_dayCell` 重写：日期 + 节假日/调休标签 + 实心时段胶囊列表（深浅编码已过/未结束）；删 `_countdownText`/`_rangeLabel`/`_cellDesignH`/l10n `cellShiftCount`；l10n 加 `holidayTag`/`makeupTag`
- [x] 行内等高 + 坐标换算：`_rowHeights` 数组 + `_rowTop`/`_rowFromY`/`_visualRowToY`/`_yToVisualRow`/`_gridContentH`；`_cellRect`/`_dateFromPosition`/`_blockPlacement`/水带（`rangeBandPath` 加 `rowHeights` 参数）/`_syncBlockFlight`/`_publishFrame` 全部适配；`_computeRowHeights(context, chain)` 按 textScaler 缩放
- [x] 今日信息卡：`_infoCard`（竖屏底部/宽屏右栏 `_sideRail`）+ `_shiftRow`/`_todayBadge`/`_adjustedBadge`/`_countdownLine` + l10n `adjustedBadge`/`countdownOver`；import day_summary（monthTallyFor）
- [x] 测试适配：calendar_screen_test 54/54（改「宽屏字号更大」为「固定字号」、拖拽用例改真实位移、窄屏今天徽章限定顶栏）；calendar 相关 83/83 全绿
- [x] 版本号 pubspec 0.14.1+182、app_info 0.14.1
- [x] zh changelog：prepend v0.14.1 条目、删 v0.11.22（保持 10 条）
- [x] en changelog：prepend v0.14.1 条目（en 头部格式确认后加上）、en v0.11.22 已删（保持 10 条）
- [x] changelog_window_test / app_info_test 跑绿（6/6）
- [x] AGENTS.md：版本史 + 最近改动 + 测试条数 **1188** 都填了
- [x] **第一轮全量 1176/15** —— 15 条失败修复：design_tokens（徽章/胶囊硬编码圆角 8/6/5、间距 2/6 → `radiusS`/`radiusL`/`spaceXs`/`padChipV`/`gapHair`）；info_card_fit（胶囊文本窄格子截断 → FittedBox；本月统计/农历行 → FittedBox；360dp small 行高差 0.18px → 呼吸 6→10）。修复后 design_tokens 24/24、info_card_fit 35/35、calendar 89/89 全绿
- [x] **term-34 第二轮全量：1188 通过 / 3 失败**（3 条容器缺字体既有失败）；基线 1187 → **1188**
- [x] **term-35 工装 1226/18**（18 条全是底栏液态拖一半既有失败）；但发现工装日历「无排班+小窗」溢出 9px（我引入：行高变小→网格矮→空态面板被挤）→ 修 `_buildGrid` 空态面板包 `SingleChildScrollView`，日历工装 52/52 绿
- [x] **term-38 完整工装（修复后重跑）11 条失败全为底栏液态既有**（与基线 term-37 一致）——确认格子改动没引入新工装失败；term-36 的 236 条是 flaky
- [x] **收尾提交完成**：beta HEAD = `f83f457`；v0.14.1 是测试版（Z≠0），按 AGENTS 规则**只留 beta、不合并 main**（main 停 0.13.0 的 9acb26e）；不打 tag
- [x] 存档 status → done（保留 7 天）

# 关键上下文
- **文件**：
  - `app/lib/features/calendar/calendar_screen.dart`（~2400 行，核心改动）
  - `app/lib/features/calendar/range_band.dart`（rangeBandPath 加 rowHeights）
  - `app/lib/features/calendar/calendar_range_band.dart`（CalendarRangeBand 加 rowHeights）
  - `app/lib/domain/shift_rotation.dart`（ShiftSegment.cellLabel）
  - `app/lib/core/l10n.dart`（holidayTag/makeupTag/adjustedBadge/countdownOver，删 cellShiftCount）
  - `app/lib/features/profile/app_dialogs.dart`（changelog）
  - `app/pubspec.yaml` 0.14.1+182、`app/lib/core/app_info.dart` 0.14.1
  - `docs/decisions-calendar-cell.md`（12 条决策）
  - 测试：`test/shift_rotation_test.dart`、`test/calendar_screen_test.dart`
- **关键决策**：
  - 行高 = 内容自然高（日期 15 + 间隔 + 胶囊数×18 + 标签 + 内缩 + 呼吸 6），乘 textScaler
  - `_computeRowHeights` 必须在 `_gridBody` 的 `_selectedRect` 前跑（否则 `_rowHeights` 空越界）
  - 块高 = 目标行实际行高（不是均分 cellH）——拖拽吸附测试抓到的
  - 格子字固定字号（不随 cellH 缩放），宽屏大空间由右栏信息卡承担
- **用户约束**：格子只留日期+时段；其他进底部信息卡；导航栏不改；0.13.0 不发、并入 0.14.0（我按 0.14.1 测试版先发，理由：格子是重大视觉改动）
- **已排除**：恢复 0.13.0 删掉的历史完整 `_infoCard`（含其他班组/待办徽章）——用户选简洁版 6 项

# 断点提示
当前停在：en changelog 的 v0.14.1 条目**没加成功**（`_changelogEn` 头部还是 `'v0.13.0\n'`，zh 已加）。原因可能是 en 的声明行格式与 zh 不同。下一步：读 `_changelogEn` 开头几行确认格式 → prepend v0.14.1 → 删 en 的 v0.11.22（文件尾部 `;` 前）→ 跑 changelog_window_test / app_info_test → 更新 AGENTS.md → 提交。
