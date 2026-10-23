---
status: in_progress
task: v0.13 六条需求：卡顿修复 + 薪资重构 + 日历倒计时 + 排班制重做 + tab 开关排序 + 系统日历同步
slug: v013-six-features
started: 2026-10-24T10:00:00Z
updated: 2026-10-24T10:50:00Z
next: 第四层：#4 新增 2h+8h 排班模板
---

# 目标

从 `0.12.2+177` 到 `0.13.0+178`，交付六条需求：
1. 修复切换页面卡顿（回归 bug）
2. 撤销月薪制、改逐月灵活填 + 加项快捷 100 + 发薪多条
3. 日历页删今日信息卡 + 格子倒计时（今天）+ 首末时段（非今天）
4. 排班制重做为「上 2 休 8 · 5 班组错开 2h · 2 天稳定周期」+ 时段名取代白班夜班
5. 设置页 tab 开关与排序（隐藏 + 后台暂停 + 数据保留）
6. 系统日历同步（单向、自动、未来 60 天、幂等标记、vivo 适配）

# 已完成

- [x] 拷打完成，32 条结论定完（见 `docs/decisions-v0.13-roadmap.md`）
- [x] 决策文件已写：`~/workspace/docs/decisions-v0.13-roadmap.md`
- [x] 上版决策文件归档：`~/workspace/docs/decisions-salary-nav.md`

# 待办

## 第一层：数据与迁移（D1、D3）✅ 已完成

- [x] schema v17 → v18：新增 `PayrollMonthlyRows` 表、`PayrollRecordRows` 主键改成 `{year, month, seq}`
- [x] `app_repository.dart`：新增 `savePayrollMonthlyConfig` / `listPayrollMonthlyConfig` / `deletePayrollMonthlyConfig`；改 `savePayrollRecord` 支持 seq
- [x] `domain/payroll.dart`：新增 `MonthlyWageConfig` 类；`computeMonthPay` 改成接收 `double monthlyWage`；`computeYearPay` 改成接收 `Map<(int, int), double>`；修复 `formatMoney` 的 `frac` 计算 bug
- [x] `backup.dart`：备份表名改成 `payroll_monthly_rows`
- [x] 单元测试全部通过：`payroll_engine_test.dart`、`payroll_repository_test.dart`、`backup_roundtrip_test.dart`、`migration_v16_to_v17_test.dart`、`stats_screen_test.dart`
- [x] `flutter analyze` 无错误

## 第二层：UI 层（D1、D2）✅ 已完成

- [x] **逐月月薪配置 UI**：`stats_screen.dart` 里的月薪设置弹层改成接收 `MonthlyWageConfig`；保存时调用 `setMonthlyWageConfig`
- [x] **加项快捷按钮"100"**：`stats_screen.dart` 里的加项弹层加了快捷按钮；`l10n.dart` 新增 `statsExtraQuick100` 文案

## 第三层：UI 层（D3）⏳ 待做

- [ ] **多条实发列表**：`stats_screen.dart` 里的实发记录从单条改成列表（同一月多条）

## 第四层：#4 新增 2h+8h 排班模板 ⏳ 待做

- [ ] `shift_templates.dart` 新增一个模板 `on_two_off_eight`（2h 值 + 8h 休 · 5 班组）
  - 注意：现有 `ShiftTemplateSpec` 结构是「周期排班」（cycle 是列表），而「2h 值 + 8h 休」是「固定排班」（每天都一样），需要修改模板结构

## 第五层：#3 日历页新布局 ✅ 已完成

- [x] 删今日信息卡（已提交 `ff320f6`）
- [x] 格子布局改 3 行（日期·岗次数 / 首末时段 / 农历）（已提交 `9ab5844`）
- [x] 今天格倒计时（已提交 `9ab5844`）
- [x] 工装矩阵验证（info_card_fit_test.dart 9 条全部通过）

⚠️ **测试状态**：`calendar_screen_test.dart` 40 条失败，主要是 `day-chip-N` key 移除和 `info-card-panel` key 移除（ff320f6 遗留）。待独立修复。

## 第六层：收尾 ⏳ 待做

- [ ] 版本号：`0.12.4+179` → `0.13.0+180`
- [ ] 更新日志：新增 v0.13.0 条目
- [ ] 全量测试 + `flutter analyze`

## 当前 git 状态（2026-10-24 新会话接手时）

```
9ab5844 feat(calendar): #3 格子布局改 3 行 + 今天格倒计时
fcdabd7 fix(webdav): 坚果云 409 兼容 + 日历格子液态档挤压场关掉 + 小组件快照格式化
47d8724 feat(payroll): v0.13 D1~D3 薪资重构——逐月月薪配置 + 加项快捷按钮 + 多条实发
54fa021 feat(calendar): 日历格子多胶囊堆叠 + 桌面小组件快照契约升级
ff320f6 feat(calendar): #3 删今日信息卡——信息合并到格子里
```

## 新会话接手步骤

1. 读本存档
2. 读 `~/workspace/docs/decisions-v0.13-roadmap.md`（决策权威）
3. 跑 `git log --oneline -15` 确认最新提交
4. 继续做 #4 新增 2h+8h 排班模板（`shift_templates.dart`）
5. 之后做 #5 tab 开关排序 + #6 系统日历同步
6. 最后收尾（版本号、更新日志、全量测试）

⚠️ **注意**：`calendar_screen_test.dart` 有 40 条测试失败，需要独立修复（主要是 `day-chip-N` 与 `info-card-panel` key 移除）。

# 关键上下文

- **当前分支**：`beta`，最新版本 `0.12.2+177`
- **决策文件**：`~/workspace/docs/decisions-v0.13-roadmap.md`（32 条 D1~D32，是本轮所有决策的唯一权威）
- **上版决策文件**：`~/workspace/docs/decisions-salary-nav.md`（T1~T10、N1~N4，本轮撤销 T1~T7）
- **AGENTS.md**：开工 SOP 必读（版本号、发布流程、坑、共享组件清单）
- **版本号规则**：`X.Y` 由用户决定，AI 只能改最后一位 `Z` 与 build；本轮由用户拍板跳 v0.13.0
- **上版已开但未发布的两个提交**：`55b3fac`（周期多选）+ `54fa021`（日历多胶囊），与本轮 #4 不冲突、保留不撤
- **项目记忆**：`container-release-build-aapt2`、`fit-tests-fail-in-container`、`migration-fixture-needs-touched-tables`

## 关键决策速查

- **D1** 撤销上版 T1 月薪制 → 逐月灵活填
- **D2** 加项快捷 100（按钮，不是默认值）
- **D3** 同月多条实发
- **D6** 删今日信息卡
- **D7、D25~D30** 倒计时只在今天格、非今天格显示首末时段、分段精度、每分钟刷新
- **D8** 5 班组错开 2h，Day 1: 0-2/10-12/20-22，2 天稳定周期
- **D9** 时段名取代白班夜班
- **D16~D18** tab 关闭 = 隐藏 + 后台暂停 + 数据保留 + 弹确认 + 可排序
- **D19~D24** 系统日历：单向、每次排班变更自动推、未来 60 天、幂等标记、vivo 走标准 API + 白名单提示、`device_calendar_plus` 插件
- **D14** v0.13.0+178
- **D32** 卡顿诊断默认路径：先关液态档对比，按「液态档开 + GT7 Pro + 每次切都卡」假设

## 关键文件（待核实）

- 排班引擎：`app/lib/domain/shift_rotation.dart`
- 数据层：`app/lib/data/app_database.dart`（schema v13，本轮要 v14）
- 日历页：`app/lib/features/calendar/`
- 薪资页：`app/lib/features/stats/stats_screen.dart`
- 排班编辑器：`app/lib/features/calendar/schedule_editor.dart`
- 导航壳：`app/lib/features/home/glass_nav_bar.dart` + `home_shell.dart`
- 设置页：`app/lib/features/profile/profile_screen.dart`
- 桌面小组件：`app/lib/features/widget/` + `android/app/src/main/java/.../ShiftWidgetBase.kt`
- L10n：`app/lib/core/l10n.dart`
- 更新日志：`app/lib/features/profile/app_dialogs.dart`

## 用户约束（逐字引用）

- 「删除月薪，年度只记录每月总记录和整年汇总」
- 「日薪按日出勤加项增加预选金额：100」（点一下填 100，非默认值）
- 「日历页面不需要下边的组件，改成显示每日的具体岗次」
- 「排班管理重构，我只想要一种，值班制上班两个小时休息8个小时」
- 「不再需要白班夜班说法」
- 「设置好的岗次可以自动同步到系统日历日程，尤其要适配vivo日历」
- 「上个版本还没那么卡」（D4 卡顿是回归 bug）

## 已排除

- ❌ 系统日历双向同步（复杂度高一档、用户不熟）
- ❌ 硬编码 vivo 私有 API（走标准 CalendarContract 更稳）
- ❌ 保留上版 T1 月薪制（用户 Q1 明确撤销）
- ❌ 撤掉上版 N3 排班多选（`55b3fac` + `54fa021` 不冲突，保留）
- ❌ 用「距明天 X 小时」这种长时间倒计时（无意义，只在今天格显示）

# 断点提示

现在停在「#3 日历页新布局已完成」。接下来做 #4 新增 2h+8h 排班模板。

⚠️ **注意**：`calendar_screen_test.dart` 有 40 条测试失败，主要是 `day-chip-N` 与 `info-card-panel` key 移除（ff320f6 遗留）。这些测试需要独立修复，与 #4 无关。
