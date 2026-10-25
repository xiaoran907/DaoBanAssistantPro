---
status: in_progress
task: v0.13 收尾：#6 系统日历同步完善 + 值班自动勿扰 + 129 条测试红修复 + 0.13.0+180 发布
slug: v013-six-features
started: 2026-10-24T10:00:00Z
updated: 2026-10-25T10:20:00Z
next: 发布前四收口已完成（提交 2704a41，beta）+ main 已并入（a03edf5）+ tag 已重指 → 等签名材料（`app/android/key.properties` + `release.jks` + `~/.aicode/github-token` chmod 600）→ 容器内 `flutter build apk --release` + `apksigner verify` 比对证书 → 手写 API 建 Release（v0.13.0）→ 传 APK → 改 main `latest.json`（stable=0.13.0）并推送 → 核对 raw（可能需用户代跑）。同一 APK 给用户真机验「v0.12.3 库升到 0.13.0」。
---

## 发布状态（2026-10-25 第三轮：四收口已并入，本地就绪，未推）
- **发布前四收口已完成**：① 自动同步接线（`maybeAutoSync` 挂冷启动闸）② 导航栏至少留一页（`setEnabled` 补下限）③ 帮助文案改口 + 补两条 ④ 本地导出/导入接入口（`MainActivity` 两个 SAF 方法 + 「我的 → 数据」两行）。提交 `2704a41`（beta），main 并入 `a03edf5`，tag `v0.13.0` 重指 a03edf5，两侧 diff 为空。
- **验证**：`flutter analyze` **0 issue**；全量 `flutter test` **1187 通过 / 3 失败**（3 条容器缺字体既有失败，非回归）；`flutter test tool/visual/` **11 条失败是既有**（`295d55a` nav #5 把 `glass-nav-bar` key 改成带后缀，工装没同步，非本轮引入）。
- **版本**：`0.13.0+180` → **`0.13.0+181`**（`pubspec.yaml`）；`app_info.dart` 仍 `0.13.0`。
- 分支与 refs：beta = **2704a41**；main = **a03edf5**；**tag `v0.13.0`（轻量）= a03edf5**（本地，未 push）；`git diff --stat beta main` 为空。
- 容器**能**发布：`github.com` / `api.github.com` / `uploads.github.com` / `codeload` / `objects` 全通、`git ls-remote` rc=0；**只有 `raw.githubusercontent.com` 被 reset**。缺的只是 `pwsh`/`gh`（release.ps1 跑不了 → 改手写 API 调用）、签名材料、PAT。
- ⚠️ **用户拍板（2026-10-25）**：#1「切换页面卡顿」与 D39（桌面小组件月历卡消费快照 v3 的 shifts）**都不进 v0.13.0**，留到 0.13.1
- ⚠️ 插队任务「日历格子可读性」原定 0.12.5+180，而本流是 0.13.0 —— **动手前必须与用户重定版本号与发布顺序**（大概率 0.13.1+181）

## 进度（2026-10-25，本会话）
- ✅ 全量测试 `/tmp/test-full4.log`：**1147 通过 / 3 失败**（上一轮基线 test-full3.log 1145/5）；剩 3 条即容器缺字体的预存失败（label_value_row「编辑器的字段标签与值 · 320dp 特大 · en」、list_subtitle_fit「待办副标题折两行，不省略」en+zh），**不是回归，勿为它改判据**
- ✅ `flutter analyze` 0 issues
- ✅ 发布收尾：`pubspec.yaml` 0.13.0+180、`app_info.dart` '0.13.0'、`app_dialogs.dart` 中英各 prepend v0.13.0 归纳条目（删最旧 v0.11.21、窗口 10 条、无 markdown）；`changelog_window_test` + `app_info_test` 6/6 绿
- ✅ 提交（beta 分支，用户 2026-10-25 说「可以」）：① `00e520b feat(v0.13): #6 系统日历同步收尾 + 值班自动勿扰`（勿扰与 #6 合并为一条，因 l10n/profile/Manifest 三文件两件事共用）；② `af3a222 fix(v0.13): 多时段排班收尾 + 日历页死码清理 + 测试适配`（app_repository 的 extraSegments 落库必须跟 ① 走，否则 ① 编译不过 —— 它调用了新签名的映射方法）
- ✅ `app/android/build/reports/problems/problems-report.html` 已 `git checkout --` 还原，不进任何提交
- ⏳ ③ `9359253 chore(release): v0.13.0+180`：pubspec / app_info / app_dialogs / docs/decisions-v0.13-roadmap.md / 本存档
- ⚠️ 未跟踪的 `.aicode/attachments/`、`gateway_connect_test.py` 属别的来源，**不提交**
- ⏳ 等用户拍板：tag/push/发布脚本那一步

## 未决范围（已拍板 2026-10-25）
- ~~#1「切换页面卡顿」~~ → **不进本版**，留 0.13.1
- ~~D39 小组件月历卡多胶囊~~ → **不进本版**，留 0.13.1

# 插队任务（2026-10-24 定，用户拍板 Q9=A）：日历格子可读性，单独发 0.12.5+180
> ⚠️ **状态：暂停中（2026-10-24 16:5x）**。发现并行会话正在做 v0.13 收尾（勿扰全套 + #6 六缺陷 + 两个新测试，13:56~16:49 未提交，还删了 `calendar_screen.dart` 491 行死代码）；用户拍板**等那条流提交后再动手**，避免两线互踩。动手前重新核实：基线行数、存留符号、版本号（那条流收尾目标是 0.13.0+180，若它先发了，本任务的版本号与发布顺序重新与用户确认）。
- 方案与决策：`docs/decisions-v0.13-roadmap.md` D33~D41（拷打第二轮，强度 4）
- [ ] 格子第 2 行改「起始钟点串」（多岗 "8·12·20" / 单岗 "8-20"；今天格倒计时规则不变）——D33 是真正的修复
- [ ] 第 2 行不再被缩到贴边：护栏断言「行 2 在字号档 1.2 × 320/360 下不被缩」（D34 订正：行级独立缩放已存在，外层整格 FittedBox 保留为高度兜底，不拆）
- [ ] 点格子 → 底部弹层当天详情（全部岗次起止 + 状态 + 其他班组 + 「调整这天」按钮；无班不弹；长按保留）
- [ ] 宽横屏右栏 = 详情栏（与弹层共用内容件，_sideRail 不再空白）；小窗恢复画网格（删 `if (!layout.isShort)` 条件）
- [ ] 小组件月历卡消费快照 v3 shifts（同款钟点串，协议不动）
- [x] 死代码：已被并行会话删（491 行 + 后续两层共 ~700 行，analyze 恢复 0/0）——⚠️ **`_otherCrewChips` 也删了**（当时全仓无调用者）；弹层「其他班组」要复用时从 git 历史（`git log -p -- app/lib/features/calendar/calendar_screen.dart`）找回
- [ ] 护栏：弹层/右栏/小窗用例 + 小组件断言 + text_fit_guard 矩阵覆盖新格子
- [ ] 收尾：0.12.5+180（pubspec + app_info）+ 更新日志（prepend 测试版条目、10 条窗口）+ 全量测试 + analyze + beta 提交（逐项确认）
- 已核实事实（2026-10-24 16:5x 重量）：**格子「挤到一起」的真正机制是第 2 行长串（"22-23→16-18" 11 字符）被自己的行级 FittedBox 缩到贴边**（左右余量≈0，日期行没缩）——之前记的「整格 FittedBox 缩水」不对，截图证实三行各自独立缩放、外层只扈高度；行级 FittedBox 已存在（[calendar_screen.dart:1868](app/lib/features/calendar/calendar_screen.dart:1868) 起）。点格子目前无弹层（onTapDown 只选中 + 触觉，:1521）。_sideRail 空壳 :908、小窗剩顶栏（`if (!layout.isShort) grid` :889）。调班入口：长按拖选 → `adjustDays`（:1140，内部走 `showShiftOverridePicker`）——弹层「调整这天」按钮可直接调 `adjustDays(date, date)`

# 目标
v0.13 收尾，四部分（方案已获批准，2026-10-24）：
1. #6 系统日历同步的六处缺陷修复
2. 值班自动勿扰（Dart + Kotlin + 权限卡）
3. 129 条测试红修复（先拿明细分类）
4. 0.13.0+180 收尾（版本 + 归纳版更新日志 + 全量测试/analyze + beta 提交）

# 已完成（v0.13 六条需求主体，全部已提交）
- [x] #2 薪资重构（47d8724）：撤销月薪制、逐月灵活填、快捷 100、发薪多条
- [x] #3 日历重做（ff320f6 + 9ab5844）：删今日信息卡、格子 3 行、今天格倒计时；测试适配（e3cdee0）
- [x] #4 值班模板（75d8e19）：duty_2_8（12 个 2h 时段班次 · 5 班组 · 5 天周期近似）
- [x] #5 tab 开关与排序（295d55a）：隐藏 + 后台暂停 + 数据保留 + 可排序
- [x] #6 系统日历同步主体（4402053 + 0ad05d4）：CalendarSyncService + CalendarEventMappingRows 表（schema v19）+ _CalendarSyncCard + Manifest 权限 + device_calendar_plus 接入

# 待办（本轮，按序）
- [ ] 重跑全量测试拿 129 条失败明细（term-2 已跑完一次：1036 通过 / 129 失败，明细只拿到尾部 4 条）
- [x] #6 缺陷 1：映射存储统一到 DB 表（CalendarSyncService 整文件重写 265 行，删 prefs JSON 双轨，_migrateLegacyPrefsMap 一次性迁移）
- [x] #6 缺陷 2：幂等键 `scheduleId:day` → `scheduleId:day:classId:seg`；表主键 {scheduleId, classId, day, seg}；v19 建表语句直接改；迁移测试 schemaVersion 期望 18→19；build_runner 已跑
- [x] #6 缺陷 3：表列 startDate/endDate → fingerprint（key|title|startMs|endMs|desc），指纹变走 updateEvent(description: Patch.set)
- [x] #6 缺陷 4：遍历 allSegments，每段一个事件；syncEventsFor 顶层纯函数
- [x] #6 缺陷 5：rescheduleAll 顶部（两 gate 之前）调 _syncCalendarIfNeeded(repo)
- [x] #6 缺陷 6：backup.dart _tableBackups 补 calendar_event_mapping_rows
- [x] 勿扰 Dart：planShiftDnd + ShiftDndPlan + reschedule 第 4 步 _rescheduleDnd（先 cancelAllNativeDnd → prefs dndEnabled → isAlarmEnabled → 8 天窗口）
- [x] 勿扰原生：AlarmScheduler.kt（DND_BASE_ID=50000，DND_DAY_SLOTS=32，8 天窗口 256 号）+ DndReceiver.kt + AlarmStore.kt（Dnd 独立键）+ BootReceiver.kt + MainActivity.kt + Manifest（ACCESS_NOTIFICATION_POLICY + receiver）
- [x] 勿扰设置：profile_screen `_ShiftDndCard`（未授权不回退开关）+ l10n 三键（shiftDnd/shiftDndSubtitle/shiftDndNoPermission）
- [x] 测试：shift_dnd_plan_test（新 7 条全过）+ calendar_sync_plan_test（新 4 条全过）；**顺带修复真缺陷：saveSchedule UPDATE/INSERT 两分支漏 extraSegments**（多段班次保存即丢）
- [x] 死码清理：calendar_screen.dart 两层死代码全删（~700 行）+ analyze 恢复 0/0（dart fix 修 12 条 info）
- [x] calendar_screen_test 36 条适配收口（2026-10-24 晚）：残缺段修复（warped 定义删、水带用例体补全）、analyze 0/0、剩 1 条「等 N 个」（测的是已删信息卡内容）整条删除 + `_shiftLine` 死 helper 删除 → **54/54 全绿**（/tmp/cal2.log）
- [x] **进行中**→✅：flutter build apk --debug（term-7）**exit 0，Built app-debug.apk**（Gradle 883.7s）——勿扰 6 文件 Kotlin 编译通过；KGP 警告（device_calendar_plus_android）是插件侧预存事项
- [x] 全量测试明细已分类（/tmp/test-full.log 128 条红）：advance_recurring 16✔、迁移簇 ~15✔、isBlank 真 bug✔、陈旧期望 7✔、calendar_screen_test 36✔、glass_tier 13（诊断中）、超时簇 ~11、散件 ~35
- [x] glass_tier_test 13 条红**全部修复（2026-10-24 深夜，27/27 绿）**——根因不是液态档：#5（295d55a）把底栏 key 从固定 `glass-nav-bar` 改成动态 `glass-nav-bar-<tab集>`（产品侧有意，tab 配置变时重建 State），7 处 `find.byKey(Key('glass-nav-bar'))` 全部失配 → 改 `find.byType(GlassNavBar)`；另 3 条 5-tab 坐标/期望：`0.85`/`0.88` 落末格（期望 3→4）、「静止时正对中心」格宽 `/4`→由 items 推导、「彩边渐入」按住点 `.18` 离格心 0.22 格滑行点亮 lit 弹簧→改按第 0 格格心。**todo_archive_screen_test 散件红同根因**（key + `0.62` 坐标 5-tab 下落到薪资页）。**产品代码零改动**。探针一次性文件已删
- [ ] 收尾：0.13.0+180（pubspec + app_info）+ 更新日志归纳版（0.12.1~0.12.4 + 本轮，prepend、删最旧、10 条窗口）+ 全量测试 + analyze + beta 提交（勿扰 / #6 / 死码清理可分提交）

# 关键上下文

## #6 缺陷清单（已核实）
1. 双重映射：Service 用 prefs 存映射，DB 表（CalendarEventMappingRows）建了但没人用
2. 幂等键冲突：`scheduleId:day` 同一天多班次/多段冲突（周期多选班次 55b3fac 已上线）
3. 时间变化不更新：`if (map.containsKey(event.key)) continue` 命中即跳过，改时间不 updateEvent
4. isAlarmEnabled/isTodoEnabled gate：rescheduleAll 开头 `if (!navConfig.isAlarmEnabled) return` 与中途 `if (!isTodoEnabled) return` 挡住末尾日历同步（alarm_service.dart:984/995 附近）
5. 备份漏登记：backup.dart _tableBackups（122~360，15 条）缺 calendar_event_mapping_rows
6. extraSegments 漏同步：_generateFutureEvents 只同步主时段

## 勿扰设计要点
- 纯函数照 planShiftAlarms（alarm_service.dart:127）模式：ShiftSource 入参、不读 DateTime.now()（from 传入）
- 从**今天**起算 8 个班次日（planShiftAlarms 从昨天起算是因为它的闹钟可落在前一天；勿扰的时刻不会落昨天）——窗口末天（d=7）跨午夜班的结束在 d=8，遍历 8 个班次日即覆盖；id 按班次日（offset）算
- id = 50000 + offset*32 + segIdx*2 + (0=on, 1=off)；段序 = allSegments 下标（主时段 0、extra 1..n）
- 时刻：开始 = DateTime(y,m,d).add(Duration(minutes: seg.start))（DateTime 重建再 add 防夏令时，照 shiftAlarmFireAt 理由）；结束 = DateTime(y,m,d + (endsNextDay?1:0)).add(Duration(minutes: endClockMinute))；endClockMinute = endMinute % 1440（ShiftClass 已有 getter）
- 跳过：那天没班 / isRest / startMinute 或 endMinute null；**不查 overrides**（勿扰跟着「那天上什么班」走，按天改班已进 shiftOn）
- reschedule() 里自查 isAlarmEnabled + dndEnabled prefs（回前台 _tryStartupReschedule 直调 reschedule 无外层 gate，已核实 home_shell.dart:289）
- 原生照 scheduleQuiet 模式：setExactAndAllowWhileIdle → DndReceiver（extra: id/dndOn），无精确权限退化非精确，落盘 AlarmStore
- DndReceiver：查 isNotificationPolicyAccessGranted（无权限记日志不动）→ setInterruptionFilter(dndOn ? INTERRUPTION_FILTER_PRIORITY : INTERRUPTION_FILTER_ALL)
- Dnd 存储独立键（AlarmStore.clear 只清 entries 的 KEY，quiets 不受影响——Dnd 照抄这个隔离）

## glass_tier_test 13 条红诊断（2026-10-24 晚，进行中）
- 失败分两类：①「交互契约两档一致」Expected 3 Actual 4（#5 后 5 tab，`lastTab` 0.85 落在第 5 格 index 4 —— **测试要适配 5 tab**，非产品 bug）；②其余 12 条液态档全报 `Found 0 widgets with type LiquidLens` / `Bad state: No element`（lensOf :346）——液态树没挂透镜
- 已核实完好：LiquidTrack 无条件画 LiquidLens（liquid_track.dart:183）；glass_nav_bar.dart:245 `ValueListenableBuilder(liquidGlassActive)` 判据链；app_settings.dart `_load()` 读 prefs 'liquidGlass' → liquidGlassEnabled → recomputeGlassTiers()
- pumpShell 机制：`SharedPreferences.setMockInitialValues({'liquidGlass': liquid})` → 依赖 HomeShell 构造 appSettingsProvider → `_load()` 异步置真；之后逐帧 pump 20 次
- 下一步探针（最快定位）：pumpShell(liquid:true) 后直接断言/print `liquidGlassEnabled.value` 与 `liquidGlassActive.value`：enabled=false → prefs 没读到或 _load 没跑（查 HomeShell 是否还 watch appSettingsProvider 触发构造）；enabled=true 而 active=false → lowEndDevice 误开；两者都 true 但树里没透镜 → ValueListenableBuilder 未重建/走了标准树（查 items.length=5 后 _buildLiquid 是否被跳过）
- 日志：/tmp/glass.log（13 条失败完整明细+堆栈）

## 文件路径
- `app/lib/features/calendar/calendar_sync_service.dart`（207 行，重构主对象）
- `app/lib/data/app_database.dart:372`（CalendarEventMappingRows 表）+ :411（DriftDatabase 清单）
- `app/lib/data/app_repository.dart:1494-1535`（get/save/deleteCalendarEventMapping）
- `app/lib/features/alarm/alarm_service.dart`（1202 行）：rescheduleAll:984、reschedule:1030、planShiftAlarms:127、scheduleNativeAlarm:535、cancelAllNativeAlarms:575、_isCalendarSyncEnabled:1004
- `app/lib/data/backup.dart:122`（_tableBackups 清单）
- `app/lib/features/profile/profile_screen.dart:1248`（_CalendarSyncCard，ConsumerStatefulWidget + prefs + initState + setState 模式）
- `app/lib/core/l10n.dart:1279`（calendarSync 键群，DND 文案加在附近）
- `app/android/app/src/main/kotlin/com/daoban/shiftassistantpro/`：AlarmScheduler.kt(288)、AlarmStore.kt(315)、BootReceiver.kt(142)、AlarmReceiver.kt(108)、MainActivity.kt(885)
- `app/android/app/src/main/AndroidManifest.xml`（16 行权限，缺 ACCESS_NOTIFICATION_POLICY）
- `app/pubspec.yaml` version: 0.12.4+179 → 0.13.0+180；`app/lib/core/app_info.dart` appVersion 同步
- `app/lib/features/profile/app_dialogs.dart` _changelogZh/_changelogEn（10 条窗口）
- 决策：`docs/decisions-v0.13-roadmap.md`（D19~D24 日历同步）

## 原生侧机制（已核实）
- AlarmScheduler.schedule = setAlarmClock → AlarmReceiver（真闹钟）；scheduleQuiet = setExactAndAllowWhileIdle → TodoReminderReceiver（安静）
- 号段：排班 0..600、自定义 10000..11000、99990..100000（旧）、TODO 20000、RECURRING 40000；DND 用 50000 起
- AlarmStore：Entry（KEY）/Quiet（独立键）+ 内存镜像；BootReceiver 读清单排回（没到点的排、过了的删）
- MainActivity.kt:559 scheduleNativeAlarm / :599 cancelAllNativeAlarms（扫 0..600、10000..11000、99990..100000 + AlarmStore.clear）；权限方法 checkBatteryOptimization 等在 :300 附近
- rescheduleAll 开头 cancelAllNativeAlarms = 清全部原生排定；DND 的 cancelAllNativeDnd 与它同段落调用

## 环境与验证
- flutter 不在 PATH：`export PATH=/opt/flutter/bin:$PATH`（/opt 下有 flutter、android-sdk）
- 全量测试基线：**128~129 失败已分类**（/tmp/test-full.log，进度见「待办」）；预存红约 8 条布局 fit（容器缺字体）
- 已知样例：todo_archive_screen_test「glass-nav-bar 找不到」（疑 #5 tab 隐藏带出）、advance_recurring_test 4 条
- device_calendar_plus 0.8.1：createEvent(calendarId,title,startDate,endDate,isAllDay,description)、updateEvent(:585)、deleteEvent({required eventId})（空 id 抛 ArgumentError）
- CalendarSyncService 的 IPC 部分容器不可测（插件静态单例）；纯函数部分可测
- 容器内跑 test + analyze；真机项需用户配合（vivo 日历事件、勿扰权限与各 ROM）

## 用户约束（逐字引用）
- 「设置好的岗次可以自动同步到系统日历日程，尤其要适配vivo日历」
- 已批准范围：#6 完善 + 值班自动勿扰 + 测试修复 + 0.13.0 收尾
- 已否决（勿重提）：工时打卡、图表统计（偏好数字列表）、多人协作、iOS 版
- 未选（日后可选）：排班分享/导出（月历 PNG + ICS）、周起始日可配
- 全部 beta 分支提交；git 提交/tag 执行时逐项确认

## 已排除
- ❌ 双向同步、硬编码 vivo 私有 API、Prefs 双轨并存
- ❌ 勿扰从昨天起算（它的时刻不会落昨天；planShiftAlarms 从昨天起算的理由不适用于勿扰）
- ❌ 勿扰查「按天关闹钟」overrides（按天改班已进 shiftOn）

# 断点提示（2026-10-25 更新）
发布收尾与提交 ①② 已完成（见上「进度」）；下一步就是 ③ + tag/push/发布，**逐项等用户确认**。

## 旧断点（已解决，留档）
勿扰全链✔（Kotlin 编译过）、#6 六缺陷✔、迁移+领域簇 109 条✔、calendar_screen_test 54/54✔、glass_tier 27/27✔——这些都在工作区**未提交**。当前停在 **超时簇 ~11 条**（recurring_dialog/screen/panel/panel_narrow/repository、todo_archive 的 TimeoutException；todo_archive 那条已证实同 glass_tier 根因——底栏动态 key + 0.62 坐标，5-tab 下落到薪资页）→ 散件（schedule_editor 6、calendar_chain 4【info-card-shift-line key 已删，断言按新入口改】、design_tokens 等）→ analyze 全局 0/0 + 全量重跑 → 0.13.0+180（pubspec + app_info + app_dialogs 归纳版日志）→ beta 提交（勿扰 / #6 / 死码清理+测试适配可分提交，逐项确认）。新会话开工先读本文件 + AGENTS.md SOP（git log / git tag / pubspec version）。
