import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/widgets/app_icon.dart';
import '../../core/widgets/centered_content.dart';
import '../../core/app_info.dart';
import '../../core/design_tokens.dart';
import '../../core/glass/glass.dart';
import '../../core/haptics.dart';
import '../../core/l10n.dart';
import '../../core/update_checker.dart';
import '../../core/widgets/glass_action_button.dart';
import '../../core/widgets/glass_dialog.dart';
import '../../core/widgets/glass_loading.dart';
import '../../core/widgets/glass_pickers.dart';
import '../../core/widgets/glass_pill.dart';
import '../../core/widgets/glass_pressable.dart';
import '../../core/widgets/glass_segment.dart';
import '../../core/widgets/glass_sheet_header.dart';
import '../../core/widgets/glass_snackbar.dart';
import '../../core/widgets/glass_switch.dart';
import '../../core/widgets/section_heading.dart';
import '../../core/theme/app_colors.dart';
import '../../data/app_repository.dart';
import '../../state/app_settings.dart';
import '../../state/nav_settings.dart';
import '../alarm/alarm_service.dart';
import '../calendar/schedule_management_screen.dart';
import '../calendar/calendar_sync_service.dart';
import 'app_dialogs.dart';
import 'backup_service.dart';
import 'help_center_screen.dart';
import 'webdav_sync_screen.dart';

/// 「我的」页：外观（主题/主色调）、数据（清空重置）、关于。
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // **「我的」页是那个例外**：主题档 / 主色 / 语言 / 液态玻璃 / 触觉五个开关都画在
    // 它自己身上，所以这五项都得订阅。收成 `language` 会把那几个开关**冻住**。
    // 写成显式的五元组而不是全量 `watch`：以后再往 `AppSettings` 加字段时，
    // 这一页不会为它白重建（builder check 抓出来的那一条）。
    final settings = ref.watch(appSettingsProvider.select((s) => (
          themeMode: s.themeMode,
          accentIndex: s.accentIndex,
          language: s.language,
          liquidGlass: s.liquidGlass,
          hapticsEnabled: s.hapticsEnabled,
          fontSize: s.fontSize,
          showLunarDay: s.showLunarDay,
        )));

    return Scaffold(
      body: SafeArea(
        child: CenteredContent(child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          physics: const BouncingScrollPhysics(),
          children: [
            Text(L10n.titleProfile, style: AppTokens.pageTitle),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionAppearance),
            GlassTile(
              translucentFill: false,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.themeMode, style: AppTokens.labelStrong),
                  const SizedBox(height: 8),
                  GlassSegment(
                    count: 3,
                    selectedIndex: settings.themeMode.index,
                    onSelected: (i) => ref
                        .read(appSettingsProvider.notifier)
                        .setThemeMode(AppThemeMode.values[i]),
                    itemBuilder: (i, selected) => Text(
                      [L10n.followSystem, L10n.light, L10n.dark][i],
                      // 基线 13px：未选中 w500、选中 w700。13 档最重的角色是 w600 的
                      // labelSecondary，两个分支都由这里显式给字重，按 spec 走 copyWith。
                      style: AppTokens.labelSecondary.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(L10n.accentColor, style: AppTokens.labelStrong),
                  const SizedBox(height: 12),
                  GlassSegment(
                    height: 40,
                    count: AppColors.accentPalette.length,
                    selectedIndex: settings.accentIndex,
                    onSelected: (i) => ref
                        .read(appSettingsProvider.notifier)
                        .setAccentIndex(i),
                    // 选中态用一圈白色描边，而不是只靠背后的药丸。
                    // 药丸的颜色就是「当前主色」，选中那格色块的填充色跟它一模一样 ——
                    // 只给药丸的话，用户反而看不见自己选中了什么颜色。
                    itemBuilder: (i, selected) => Container(
                      width: 26,
                      height: 26,
                      padding: const EdgeInsets.all(AppTokens.gapHair),
                      decoration: BoxDecoration(
                        color: selected ? Colors.white : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.accentPalette[i],
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(L10n.language, style: AppTokens.labelStrong),
                  const SizedBox(height: 8),
                  GlassSegment(
                    count: 2,
                    selectedIndex: settings.language == 'en' ? 1 : 0,
                    onSelected: (i) => ref
                        .read(appSettingsProvider.notifier)
                        .setLanguage(i == 0 ? 'zh' : 'en'),
                    itemBuilder: (i, selected) => Text(
                      i == 0 ? '中文' : 'English',
                      // 基线 13px：未选中 w500、选中 w700。13 档最重的角色是 w600 的
                      // labelSecondary，两个分支都由这里显式给字重，按 spec 走 copyWith。
                      style: AppTokens.labelSecondary.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 字号四档（设计 §3）：**这是全 app 唯一的字号来源** ——
                  // 根部那层 `MediaQuery` 已经把系统报上来的 `textScaler` 整个换掉了。
                  Text(L10n.fontSize, style: AppTokens.labelStrong),
                  const SizedBox(height: 8),
                  GlassSegment(
                    count: AppFontSize.values.length,
                    selectedIndex: settings.fontSize.index,
                    onSelected: (i) => ref
                        .read(appSettingsProvider.notifier)
                        .setFontSize(AppFontSize.values[i]),
                    itemBuilder: (i, selected) => FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        // 英文那几档**特意取短**（`XL` 而不是 `Extra large`）：
                        // 320dp 上四格每格只有约 48dp 可用。
                        //
                        // 外面那层 `FittedBox(scaleDown)` 是护栏逼出来的：`Standard`
                        // 在 320dp@英文下比格子宽 4px，`GlassSegment` 会**静默裁掉**
                        // 那 4px —— 而那正是「字被吃掉」的一种，段落自己（`maxLines`）
                        // 一点都不知道。按设计 §2 的第 2 档降级：缩，不省略。
                        [
                          L10n.fontSmall,
                          L10n.fontStandard,
                          L10n.fontLarge,
                          L10n.fontExtraLarge,
                        ][i],
                        // 基线 13px：未选中 w500、选中 w700。13 档最重的角色是 w600 的
                        // labelSecondary，两个分支都由这里显式给字重，按 spec 走 copyWith。
                        style: AppTokens.labelSecondary.copyWith(
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(L10n.liquidGlass,
                                style: AppTokens.labelStrong),
                            const SizedBox(height: AppTokens.gapHair),
                            Text(
                                // 低内存机器上这一档被 `!lowEndDevice` 挡掉：
                                // 开关置灰 + 换一句说明。**不能让它看着能开、
                                // 开了什么也不发生** —— 那比直接说不可用更糟
                                // （spec §1 的成功标准：回落并说明原因、不静默无反应）。
                                lowEndDevice
                                    ? L10n.liquidGlassUnsupportedHint
                                    : L10n.liquidGlassHint,
                                style: AppTokens.microText
                                    .copyWith(color: AppTokens.inkMuted(context))),
                          ],
                        ),
                      ),
                      GlassSwitch(
                        value: settings.liquidGlass,
                        enabled: !lowEndDevice,
                        onChanged: (v) => ref
                            .read(appSettingsProvider.notifier)
                            .setLiquidGlass(v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(L10n.settingShowLunarDay,
                                style: AppTokens.labelStrong),
                            const SizedBox(height: AppTokens.gapHair),
                            Text(L10n.settingShowLunarDayHint,
                                style: AppTokens.microText
                                    .copyWith(color: AppTokens.inkMuted(context))),
                          ],
                        ),
                      ),
                      GlassSwitch(
                        value: settings.showLunarDay,
                        onChanged: (v) => ref
                            .read(appSettingsProvider.notifier)
                            .setShowLunarDay(v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(L10n.hapticFeedback,
                                style: AppTokens.labelStrong),
                            const SizedBox(height: AppTokens.gapHair),
                            Text(L10n.hapticFeedbackHint,
                                style: AppTokens.microText
                                    .copyWith(color: AppTokens.inkMuted(context))),
                          ],
                        ),
                      ),
                      GlassSwitch(
                        value: settings.hapticsEnabled,
                        onChanged: (v) => ref
                            .read(appSettingsProvider.notifier)
                            .setHapticsEnabled(v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionNav),
            const _NavSettingsCard(),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionSchedule),
            GlassTile(
              translucentFill: false,
              padding: EdgeInsets.zero,
              child: GlassPressable(
                child: ListTile(
                  leading: const Icon(Icons.tune_outlined),
                  title: Text(L10n.scheduleManagement),
                  subtitle: Text(L10n.scheduleManagementSubtitle),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ScheduleManagementScreen()),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionDesktop),
            GlassTile(
              translucentFill: false,
              padding: EdgeInsets.zero,
              child: GlassPressable(
                child: ListTile(
                  leading: const Icon(Icons.widgets_outlined),
                  title: Text(L10n.guideWidgetTitle),
                  subtitle: Text(L10n.widgetEntrySubtitle),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  // 从前这里弹自己那一份小组件说明；v0.11.17 起**跳进《使用帮助》
                  // 并翻到「桌面小组件」那一节** —— 全 app 只剩一份文案。
                  // 这一行本身留着：它也是「原来还有桌面小组件」的发现点。
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            const HelpCenterScreen(scrollToWidgets: true)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionAlarm),
            // 铃声与贪睡时长是同一类东西（都是「响了之后怎么响」），摆在一张卡里，
            // 中间用全 app 那条 `Divider(height: 1)` 配方（同「关于」那一节）。
            GlassTile(
              translucentFill: false,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _RingtoneRow(onPick: () => _showRingtonePicker(context, ref)),
                  const Divider(height: 1),
                  const _SnoozeRow(),
                  const Divider(height: 1),
                  const _FadeInRow(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionData),
            // 云同步与清空重置都是「整份数据」的事，摆一张卡里（同「闹钟」那一张：
            // 一行一个动作，中间 `Divider(height: 1)`）。
            GlassTile(
              translucentFill: false,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.cloud_sync_outlined),
                      title: Text(L10n.webdavTitle),
                      subtitle: Text(L10n.webdavEntrySubtitle),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const WebDavSyncScreen()),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  // 本地导出 / 导入：不依赖网盘，把整份数据存成一个文件。
                  // 换手机那条帮助文案（v0.13.0 起）说的就是这两行 + WebDAV。
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.file_download_outlined),
                      title: Text(L10n.exportBackup),
                      subtitle: Text(L10n.exportBackupSubtitle),
                      onTap: () => BackupService.exportData(context, ref),
                    ),
                  ),
                  const Divider(height: 1),
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.file_upload_outlined),
                      title: Text(L10n.importBackup),
                      subtitle: Text(L10n.importBackupSubtitle),
                      onTap: () => BackupService.importData(context, ref),
                    ),
                  ),
                  const Divider(height: 1),
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.delete_sweep_outlined,
                          color: AppTokens.danger),
                      title: Text(L10n.clearReset),
                      subtitle: Text(L10n.clearResetSubtitle),
                      onTap: () => _confirmReset(context, ref),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionHeading(L10n.calendarSync),
            const _CalendarSyncCard(),
            const SizedBox(height: 16),
            SectionHeading(L10n.shiftDnd),
            const _ShiftDndCard(),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionPermission),
            const _PermissionCheck(),
            const SizedBox(height: 16),
            SectionHeading(L10n.sectionAbout),
            GlassTile(
              translucentFill: false,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outlined),
                    title: Text(L10n.version),
                    trailing: const Text('v$appVersion'),
                  ),
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.system_update_outlined),
                      title: Text(L10n.checkUpdate),
                      subtitle: Text(L10n.checkUpdateSubtitle),
                      onTap: () => _checkUpdate(context),
                    ),
                  ),
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.new_releases_outlined),
                      title: Text(L10n.changelog),
                      subtitle: Text(L10n.changelogSubtitle),
                      onTap: () => showChangelogDialog(context),
                    ),
                  ),
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.help_outlined),
                      title: Text(L10n.usageGuide),
                      subtitle: Text(L10n.usageGuideSubtitle),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const HelpCenterScreen()),
                      ),
                    ),
                  ),
                  GlassPressable(
                    child: ListTile(
                      leading: const Icon(Icons.bug_report_outlined),
                      title: Text(L10n.viewLog),
                      subtitle: Text(L10n.viewLogSubtitle),
                      onTap: () => _showLog(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final r = await UpdateChecker.checkUpdates();
    if (!context.mounted) return;
    if (r.error) {
      showUpdateFailedDialog(context);
      return;
    }
    showUpdateDialog(context, r);
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: L10n.confirmResetTitle,
        content: Text(L10n.confirmResetContent),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            label: L10n.cancel,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            variant: GlassActionVariant.danger,
            onPressed: () => Navigator.pop(dialogContext, true),
            label: L10n.confirmResetAction,
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final repo = ref.read(appRepositoryProvider);
      // 「清空重置」= **回到第一次安装的样子**（2026-10-01 用户定）。库以外还有几样
      // 也得跟着回去，此前漏了：
      //   · 我保存的铃声文件（留在应用目录里，谁也再看不到它，白占空间）
      //   · 外观那一组设置（主题 / 主色调 / 语言 / 高级材质 / 触觉）
      //   · 首启标记与小组件快照（都在同一份 SharedPreferences 里）
      // 至于原生已排的班次闹钟、通知与待办提醒：`rescheduleAll` 按刚重置好的空库
      // 重排一遍，等于全撤（它自己会先 cancelAll）。
      await repo.clearAll();
      await AlarmService.clearRingtoneFile();
      final sp = await SharedPreferences.getInstance();
      await sp.clear();
      ref.read(appSettingsProvider.notifier).resetToDefaults();
      ref.read(navSettingsProvider.notifier).resetToDefaults();
      // **放在清 prefs 之后**：这一步会把上面几样一起算进推给桌面的快照里。
      await AlarmService.rescheduleAll(repo);
      if (context.mounted) {
        showGlassSnack(context, L10n.resetDone, icon: Icons.check_circle_outlined);
      }
    }
  }

  Future<void> _showLog(BuildContext context) async {
    final log = await AlarmService.readLog();
    if (!context.mounted) return;
    await showGlassDialog<void>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: L10n.log,
        showClose: true,
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              log.isEmpty ? L10n.noLog : log,
              style: AppTokens.microText.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          GlassActionButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: log));
              if (dialogContext.mounted) {
                showGlassSnack(dialogContext, L10n.logCopied,
                    icon: Icons.content_copy_outlined);
              }
            },
            label: L10n.copy,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () async {
              await AlarmService.clearLog();
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            label: L10n.clear,
          ),
        ],
      ),
    );
  }

  /// 选择器里「不是铃声 URI」的两个动作。带 `action:` 前缀，不会和系统铃声的
  /// `content://` 或自选铃声的 `file://` 撞上。
  static const String _actionPickFile = 'action:pickFile';
  static const String _actionRemoveFile = 'action:removeFile';

  Future<void> _showRingtonePicker(BuildContext context, WidgetRef ref) async {
    final sp = await SharedPreferences.getInstance();
    // 没存 = 内置铃声（不是存了 'builtin'，见下面写入的分支）。
    final current = sp.getString('ringtoneUri');
    final currentTitle = sp.getString('ringtoneTitle');
    final ringtones = await AlarmService.listRingtones();
    if (!context.mounted) return;

    final selection = await showGlassSheet<String>(
      context: context,
      builder: (sheetContext) => GlassPanel(
        solid: true,
        margin: const EdgeInsets.all(12),
        borderRadius: const BorderRadius.all(Radius.circular(AppTokens.radiusXL)),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头部走共享件（把手 + 主色竖条 + 标题 + 分隔线）。
              GlassSheetHeader(title: L10n.ringtone),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    GlassPressable(
                      child: ListTile(
                        leading: const Icon(Icons.alarm_outlined),
                        title: Text(L10n.builtinRingtone),
                        subtitle: Text(L10n.builtinRingtoneSubtitle),
                        trailing: _ringtoneTrailing(
                          context,
                          selected: current == null,
                          onPreview: () => AlarmService.playRingtone(null),
                        ),
                        onTap: () => Navigator.pop(sheetContext, 'builtin'),
                      ),
                    ),
                    // 「仅震动」与内置铃声同级：两者都不碰自选文件，都是「不指定音源」
                    // 的一档。放在这里而不是列表末尾，是因为设置铃声的人第一眼就该
                    // 看到它 —— 用户反馈的就是「不想响、只想震」，让它埋在系统铃声
                    // 底下等于没做。
                    GlassPressable(
                      child: ListTile(
                        leading: const Icon(Icons.vibration),
                        title: Text(L10n.vibrateOnlyRingtone),
                        subtitle: Text(L10n.vibrateOnlyRingtoneSubtitle),
                        trailing: _ringtoneTrailing(
                          context,
                          selected: current == AlarmService.vibrateOnlyRingtone,
                          // 试听这一档就是**震一下**（原生侧走一次性震动）。
                          onPreview: () => AlarmService.playRingtone(
                              AlarmService.vibrateOnlyRingtone),
                        ),
                        onTap: () => Navigator.pop(
                            sheetContext, AlarmService.vibrateOnlyRingtone),
                      ),
                    ),
                    // 自选铃声：只在真的设过时出现，免得平时多占一行。
                    if (_isFileRingtone(current))
                      GlassPressable(
                        child: ListTile(
                          leading: const Icon(Icons.music_note_outlined),
                          title: Text(
                            (currentTitle == null || currentTitle.isEmpty)
                                ? L10n.myRingtone
                                : currentTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(L10n.myRingtone),
                          trailing: _ringtoneTrailing(
                            context,
                            selected: true,
                            onPreview: () => AlarmService.playRingtone(current),
                            onRemove: () =>
                                Navigator.pop(sheetContext, _actionRemoveFile),
                          ),
                          onTap: () => Navigator.pop(sheetContext, current),
                        ),
                      ),
                    GlassPressable(
                      child: ListTile(
                        leading: const Icon(Icons.folder_open_outlined),
                        title: Text(L10n.pickRingtoneFromFile),
                        // 复制进私有目录这件事要写明白：用户有权知道选中的文件
                        // 被怎么处理了。
                        subtitle: Text(L10n.pickRingtonePrivacy),
                        onTap: () =>
                            Navigator.pop(sheetContext, _actionPickFile),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(L10n.systemRingtones,
                          style: AppTokens.labelStrong),
                    ),
                    ...ringtones.map((r) => GlassPressable(
                          child: ListTile(
                            leading: const Icon(Icons.music_note_outlined),
                            title: Text(r.title),
                            trailing: _ringtoneTrailing(
                              context,
                              selected: current == r.uri,
                              onPreview: () => AlarmService.playRingtone(r.uri),
                            ),
                            onTap: () => Navigator.pop(sheetContext, r.uri),
                          ),
                        )),
                    if (ringtones.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(L10n.noRingtones),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await AlarmService.stopRingtone();
    if (selection == null || !context.mounted) return;

    if (selection == _actionPickFile) {
      await _pickRingtoneFile(context, ref, sp);
      return;
    }

    if (selection == _actionRemoveFile) {
      await AlarmService.clearRingtoneFile();
      await sp.remove('ringtoneUri');
      await sp.remove('ringtoneTitle');
      await _rescheduleAlarms(ref);
      if (context.mounted) {
        showGlassSnack(context, L10n.ringtoneFileRemoved,
            icon: Icons.delete_outline);
      }
      return;
    }

    if (selection == 'builtin') {
      // 换回内置铃声：把复制进来的文件删掉，别在私有目录里留垃圾。
      await AlarmService.clearRingtoneFile();
      await sp.remove('ringtoneUri');
      await sp.remove('ringtoneTitle');
    } else if (_isFileRingtone(selection)) {
      await sp.setString('ringtoneUri', selection);
    } else {
      // 其余两种：系统铃声 URI（`content://`）与「仅震动」哨兵（见
      // `AlarmService.vibrateOnlyRingtone`）。两者都是「直接把这个值存进去」——
      // 原生侧认的是同一个键，不需要在这里分叉。同样清掉自选文件。
      //
      // **哨兵这一档别写成 `remove('ringtoneUri')`**：删掉这个键的含义是「内置铃声」，
      // 用户选了静音、闹钟反而响起来。
      await AlarmService.clearRingtoneFile();
      await sp.setString('ringtoneUri', selection);
      await sp.remove('ringtoneTitle');
    }
    await _rescheduleAlarms(ref);
    if (context.mounted) {
      final vibrateOnly = selection == AlarmService.vibrateOnlyRingtone;
      showGlassSnack(
        context,
        selection == 'builtin'
            ? L10n.setBuiltinRingtone
            : vibrateOnly
                ? L10n.setVibrateOnlyRingtone
                : L10n.ringtoneSet,
        icon: vibrateOnly ? Icons.vibration : Icons.music_note_outlined,
      );
    }
  }

  /// 「我的铃声」那一行的判断依据：自选铃声存的是 `file://` 路径，
  /// 内置是没存、系统铃声是 `content://`。
  static bool _isFileRingtone(String? uri) =>
      uri != null && uri.startsWith('file://');

  /// 列表行右侧：试听按钮 +（自选铃声那行再加一个）移除按钮 + 选中对勾。
  Widget _ringtoneTrailing(
    BuildContext context, {
    required bool selected,
    required VoidCallback onPreview,
    VoidCallback? onRemove,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.play_circle_outlined),
          tooltip: L10n.preview,
          onPressed: onPreview,
        ),
        if (onRemove != null)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: L10n.removeRingtone,
            onPressed: onRemove,
          ),
        if (selected)
          AppIcon(Icons.check,
              size: AppTokens.iconMd,
              color: Theme.of(context).colorScheme.primary),
      ],
    );
  }

  Future<void> _pickRingtoneFile(
      BuildContext context, WidgetRef ref, SharedPreferences sp) async {
    try {
      final picked = await AlarmService.pickRingtoneFile();
      // 用户按返回取消了 —— 什么都不做，也不提示。
      if (picked == null || !context.mounted) return;
      // 这里**不要**再调 clearRingtoneFile：原生侧复制新文件之前已经把旧的那份
      // 删掉了，再清一次会把刚复制进来的这个也删掉。
      await sp.setString('ringtoneUri', picked.uri);
      await sp.setString('ringtoneTitle', picked.name);
      await _rescheduleAlarms(ref);
      if (context.mounted) {
        showGlassSnack(context, L10n.ringtoneSet,
            icon: Icons.music_note_outlined);
      }
    } on RingtonePickException catch (e) {
      // 「太大」和「读不出来」要说成两句不同的话，否则用户只会反复重试同一个文件。
      if (!context.mounted) return;
      showGlassSnack(
        context,
        e.isTooLarge ? L10n.ringtoneTooLarge : L10n.ringtoneCopyFailed,
        icon: Icons.error_outline,
      );
    }
  }

  Future<void> _rescheduleAlarms(WidgetRef ref) async {
    await AlarmService.rescheduleAll(ref.read(appRepositoryProvider));
  }
}

/// 「闹钟铃声」这一行：副标题显示**当前生效的那一档**。
///
/// 为什么它必须是个 StatefulWidget：铃声存在 SharedPreferences 里，不在任何 provider
/// 里，选择层改完之后这一行不会自己重建。不重读的话，用户刚把铃声设成「仅震动」、
/// 退回来却还写着「选择内置、系统、你的铃声，或「仅震动」」—— 会以为自己没设成功，
/// 而这一档设没设成功是**听不出来的**（要等到下次响铃才知道）。
///
/// 副标题只区分**模式**，不显示系统铃声的具体名字：那要先过 `listRingtones()` 拿
/// uri→名字的对应（列表里才有），为一行副标题多付一次原生通道调用不值当。自选铃声
/// 的名字是选的时候顺手存下来的（`ringtoneTitle`），直接读就有。
class _RingtoneRow extends ConsumerStatefulWidget {
  const _RingtoneRow({required this.onPick});

  /// 弹出选择层；返回后本组件重读一次设置。
  final Future<void> Function() onPick;

  @override
  ConsumerState<_RingtoneRow> createState() => _RingtoneRowState();
}

class _RingtoneRowState extends ConsumerState<_RingtoneRow> {
  String? _uri;
  String? _title;

  /// 还没读出来时用 `false` 区分「读到的是内置」和「还没读到」—— 读设置要过一次
  /// 异步，首帧必然还没有值。
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? uri;
    String? title;
    try {
      final sp = await SharedPreferences.getInstance();
      uri = sp.getString('ringtoneUri');
      title = sp.getString('ringtoneTitle');
    } catch (_) {
      // 读不到（极少见）就退回那句泛泛的提示，不抛给界面 —— 这一行不该因为读设置
      // 失败而把整页带崩。
    }
    if (!mounted) return;
    setState(() {
      _uri = uri;
      _title = title;
      _loaded = true;
    });
  }

  String get _subtitle {
    if (!_loaded) return L10n.ringtoneSubtitle;
    final uri = _uri;
    if (uri == AlarmService.vibrateOnlyRingtone) {
      return L10n.vibrateOnlyRingtone;
    }
    // 没存这个键 = 内置（不是存了 'builtin'，见 `_showRingtonePicker` 的写入分支）。
    if (uri == null || uri.isEmpty) return L10n.builtinRingtone;
    if (uri.startsWith('file://')) {
      final t = _title?.trim();
      return (t == null || t.isEmpty) ? L10n.myRingtone : t;
    }
    return L10n.systemRingtones;
  }

  @override
  Widget build(BuildContext context) => GlassPressable(
        child: ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: Text(L10n.ringtone),
          subtitle:
              Text(_subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_outlined),
          onTap: () async {
            await widget.onPick();
            if (mounted) await _load();
          },
        ),
      );
}

/// 「贪睡时长」那一行。摆法照 `_RingtoneRow`：**自读自写 prefs、选完自己重读一次**。
///
/// 为什么不进 `appSettings`：响铃界面要读它，而那个界面是原生 intent 拉起来的、
/// **不 watch** 任何 provider（见 `AlarmService.snoozeMinutes` 的注释）。prefs 是
/// 两边的共同真源，铃声也是这么办的。
class _SnoozeRow extends StatefulWidget {
  const _SnoozeRow();

  @override
  State<_SnoozeRow> createState() => _SnoozeRowState();
}

class _SnoozeRowState extends State<_SnoozeRow> {
  int _minutes = L10n.snoozeDefaultMinutes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await AlarmService.snoozeMinutes();
    if (!mounted) return;
    setState(() => _minutes = m);
  }

  Future<void> _pick() async {
    final picked = await showGlassOptionPicker<int>(
      context,
      title: L10n.snoozeDuration,
      options: L10n.snoozeOptions,
      labelOf: L10n.snoozeOptionLabel,
      selected: _minutes,
    );
    // null = 点外面关掉了，保持原值不动（与待办提醒那一处同一句判据）。
    if (picked == null) return;
    await AlarmService.setSnoozeMinutes(picked);
    await _load();
  }

  @override
  Widget build(BuildContext context) => GlassPressable(
        child: ListTile(
          leading: const Icon(Icons.snooze_outlined),
          title: Text(L10n.snoozeDuration),
          // 副标题把**现在是多少**写出来 —— 铃声那一行也是这个规矩：这一档设没设
          // 成功，光看是看不出来的。
          // 折两行、不省略（设计 §6.3）：`「再睡一会」之后隔 5 分钟重新响铃`
          // 在 360dp 标准档下就已经超出一行 —— 那是**最常见**的配置，不是极端。
          subtitle: Text(
            L10n.snoozeDurationSubtitle(_minutes),
            maxLines: 2,
          ),
          trailing: const Icon(Icons.chevron_right_outlined),
          onTap: _pick,
        ),
      );
}

/// 铃声渐响开关：响了之后音量从低到高（用户 2026-10-25 要求，放「闹钟」卡里）。
class _FadeInRow extends ConsumerStatefulWidget {
  const _FadeInRow();

  @override
  ConsumerState<_FadeInRow> createState() => _FadeInRowState();
}

class _FadeInRowState extends ConsumerState<_FadeInRow> {
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await AlarmService.fadeInEnabled();
    if (!mounted) return;
    setState(() => _enabled = v);
  }

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.volume_up_outlined),
        title: Text(L10n.fadeInRingtone),
        subtitle: Text(L10n.fadeInRingtoneSubtitle,
            maxLines: 2,
            style: AppTokens.rowSecondary
                .copyWith(color: AppTokens.inkMuted(context))),
        trailing: GlassSwitch(
          value: _enabled,
          onChanged: (v) async {
            setState(() => _enabled = v);
            await AlarmService.setFadeInEnabled(v);
            Haptics.commit();
          },
        ),
      );
}

/// 权限检测卡：展示通知 + 精确闹钟权限状态，未开启时可一键跳转系统开启。
class _PermissionCheck extends ConsumerStatefulWidget {
  const _PermissionCheck();

  @override
  ConsumerState<_PermissionCheck> createState() => _PermissionCheckState();
}

class _PermissionCheckState extends ConsumerState<_PermissionCheck>
    with WidgetsBindingObserver {
  bool? _notif;
  bool? _exact;
  bool? _overlay;
  bool? _fsi;
  bool? _battery;
  bool? _miui;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页返回（App 回到前台）时，重新检测权限，保证状态实时。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final (notif, exact) = await AlarmService.checkPermissions();
    final overlay = await AlarmService.checkOverlayPermission();
    final fsi = await AlarmService.checkFullScreenIntentPermission();
    final battery = await AlarmService.checkBatteryOptimization();
    final miui = await AlarmService.checkMiuiPermissionPage();
    if (!mounted) return;
    setState(() {
      _notif = notif;
      _exact = exact;
      _overlay = overlay;
      _fsi = fsi;
      _battery = battery;
      _miui = miui;
    });
  }

  Future<void> _openNotifications() async {
    await AlarmService.requestNotificationsPermission();
    await _refresh();
  }

  Future<void> _openExactAlarms() async {
    await AlarmService.requestExactAlarmsPermission();
    await _refresh();
  }

  Future<void> _openAutoStart() async {
    await AlarmService.openAppSettings();
  }

  /// 小米那项「后台弹出界面」读不到状态，只能送到那个页面让用户自己开；
  /// 万一页面打不开（非小米或 ROM 拦了），落回系统「应用信息」页。
  Future<void> _openMiuiPermissionPage() async {
    final ok = await AlarmService.openMiuiPermissionPage();
    if (!ok) await AlarmService.openAppSettings();
  }

  Future<void> _openOverlay() async {
    await AlarmService.openOverlaySettings();
    await _refresh();
  }

  Future<void> _openFullScreenIntent() async {
    await AlarmService.openFullScreenIntentSettings();
    await _refresh();
  }

  Future<void> _openBattery() async {
    await AlarmService.requestIgnoreBatteryOptimizations();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appSettingsProvider.select((s) => s.language)); // 语言切换时重建（权限卡文案也要实时刷新）
    final loading = _notif == null ||
        _exact == null ||
        _overlay == null ||
        _fsi == null ||
        _battery == null;
    return GlassTile(
      translucentFill: false,
      padding: const EdgeInsets.fromLTRB(
          4, AppTokens.gapIconText, 4, AppTokens.gapIconText),
      child: loading
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: GlassLoading(size: 24),
                  ),
                  const SizedBox(width: 12),
                  Text(L10n.permChecking),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _groupHeader(context, L10n.permGroupBasic),
                _permTile(
                  icon: _notif!
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  title: L10n.permNotif,
                  subtitle: _notif! ? L10n.enabled : L10n.permNotifOff,
                  enabled: _notif!,
                  onOpen: _openNotifications,
                ),
                const Divider(height: 1),
                _permTile(
                  icon: _exact! ? Icons.alarm_on_outlined : Icons.alarm_off_outlined,
                  title: L10n.permExact,
                  subtitle: _exact! ? L10n.enabled : L10n.permExactOff,
                  enabled: _exact!,
                  onOpen: _openExactAlarms,
                ),
                _groupHeader(context, L10n.permGroupFullscreen),
                _permTile(
                  icon: Icons.aspect_ratio_outlined,
                  title: L10n.permOverlay,
                  subtitle: _overlay! ? L10n.enabled : L10n.permOverlayHint,
                  enabled: _overlay!,
                  onOpen: _openOverlay,
                ),
                const Divider(height: 1),
                _permTile(
                  icon: Icons.fullscreen_outlined,
                  title: L10n.permFsi,
                  subtitle: _fsi! ? L10n.enabled : L10n.permFsiHint,
                  enabled: _fsi!,
                  onOpen: _openFullScreenIntent,
                ),
                // 下面两行只在小米机型出现：它们是 MIUI 私有的权限，别家没有，摆出来
                // 只会让人白跑一趟。状态都读不到（没有公开 API），所以是「去查看」
                // 而不是开关态 —— 也正是因此要**分成两行**：一个的症状是「退到后台
                // 不弹」，另一个是「锁屏不弹」，用户能各自对号入座。
                if (_miui == true) ...[
                  const Divider(height: 1),
                  _permTile(
                    icon: Icons.open_in_new_outlined,
                    title: L10n.permMiuiPopup,
                    subtitle: L10n.permMiuiPopupHint,
                    enabled: null,
                    onOpen: _openMiuiPermissionPage,
                    actionLabel: L10n.goCheck,
                  ),
                  const Divider(height: 1),
                  _permTile(
                    icon: Icons.screen_lock_portrait_outlined,
                    title: L10n.permMiuiLockScreen,
                    subtitle: L10n.permMiuiLockScreenHint,
                    enabled: null,
                    onOpen: _openMiuiPermissionPage,
                    actionLabel: L10n.goCheck,
                  ),
                ],
                _groupHeader(context, L10n.permGroupBackground),
                _permTile(
                  icon: Icons.power_settings_new_outlined,
                  title: L10n.permAutoStart,
                  subtitle: L10n.permAutoStartHint,
                  enabled: null, // 系统不提供检测，始终显示「去查看」
                  onOpen: _openAutoStart,
                  actionLabel: L10n.goCheck,
                ),
                const Divider(height: 1),
                _permTile(
                  icon: Icons.battery_saver_outlined,
                  title: L10n.permBattery,
                  subtitle: _battery! ? L10n.enabled : L10n.permBatteryHint,
                  enabled: _battery!,
                  onOpen: _openBattery,
                ),
              ],
            ),
    );
  }

  Widget _groupHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: AppTokens.labelSecondary
            .copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }

  Widget _permTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool? enabled,
    required VoidCallback onOpen,
    String? actionLabel,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: enabled == true
          ? null
          // 「去开启」：**玻璃胶囊**（与全 app 的入口同款）。原来是一颗裸
          // `TextButton`，读起来像正文、不像能点的东西。**外面套 `IntrinsicWidth`
          // 是必须的**：`ListTile.trailing` 给的是**有限宽度**，而 `GlassPill` 里那个
          // `Container` 带了 `alignment`、拿到有限宽度就会**铺满整行**
          // （同 v0.11.4「已完成 N 条」那个坑：不套的话它长得跟一条行一样宽）。
          // `height: 36` 是「紧凑入口」那一档（见 `GlassPill` 文档注释）—— 别退回
          // 32：这几项权限只有这一处入口，命中区缩水不值当。
          : IntrinsicWidth(
              child: GlassPill(
                onTap: onOpen,
                height: 36,
                child: Text(
                  actionLabel ?? L10n.goEnable,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTokens.labelSecondary.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
    );
  }
}

/// 导航栏设置卡片：开关 tab + 拖拽排序。
class _NavSettingsCard extends ConsumerWidget {
  const _NavSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navConfig = ref.watch(navSettingsProvider);

    return GlassTile(
      translucentFill: false,
      padding: EdgeInsets.zero,
      child: ReorderableListView(
        key: const Key('nav-reorder-list'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        onReorderItem: (oldIndex, newIndex) {
          final order = navConfig.order;
          if (oldIndex < 0 || oldIndex >= order.length) return;
          final id = order[oldIndex];
          ref.read(navSettingsProvider.notifier).reorder(
                id: id, newIndex: newIndex);
        },
        children: [
          for (final id in navConfig.order) _NavTabRow(
            key: ValueKey(id),
            id: id,
            enabled: navConfig.isEnabled(id),
          ),
        ],
      ),
    );
  }

  static const _allTabDefs = [
    (NavTabId.calendar, Icons.calendar_month_outlined),
    (NavTabId.alarm, Icons.alarm_outlined),
    (NavTabId.todo, Icons.event_note_outlined),
    (NavTabId.salary, Icons.account_balance_wallet_outlined),
    (NavTabId.profile, Icons.person_outlined),
  ];
}

/// 单个 tab 行：图标 + 名称 + 开关。
class _NavTabRow extends ConsumerWidget {
  const _NavTabRow({super.key, required this.id, required this.enabled});

  final NavTabId id;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final def = _NavSettingsCard._allTabDefs
        .firstWhere((d) => d.$1 == id);
    final title = switch (id) {
      NavTabId.calendar => L10n.navCalendar,
      NavTabId.alarm => L10n.navAlarm,
      NavTabId.todo => L10n.navTodo,
      NavTabId.salary => L10n.navSalary,
      NavTabId.profile => L10n.navProfile,
    };

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(def.$2, size: AppTokens.iconMd),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: AppTokens.labelStrong)),
          // 「我的」是底栏固定的一项：关掉就进不来这个设置页（连重新打开
          // 「我的」都做不到，只能重装）。所以它不显示开关，改用固定文字。
          if (id == NavTabId.profile)
            Text(L10n.navFixedProfile,
                style: AppTokens.labelSecondary
                    .copyWith(color: AppTokens.inkMuted(context)))
          else
            GlassSwitch(
              value: enabled,
              onChanged: (v) async {
                if (!v) {
                  final confirmed = await showGlassDialog<bool>(
                    context: context,
                    builder: (dialogContext) => GlassDialog(
                      title: L10n.navConfirmOffTitle,
                      content: Text(L10n.navConfirmOffContent(title)),
                      actions: [
                        GlassActionButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          label: L10n.cancel,
                        ),
                        const SizedBox(width: 8),
                        GlassActionButton(
                          variant: GlassActionVariant.danger,
                          onPressed: () => Navigator.pop(dialogContext, true),
                          label: L10n.confirmResetAction,
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                }
                ref
                    .read(navSettingsProvider.notifier)
                    .setEnabled(id, v);
              },
            ),
        ],
      ),
    );
  }
}

/// 系统日历同步卡片：开关 + 选择日历 + 同步按钮。
class _CalendarSyncCard extends ConsumerStatefulWidget {
  const _CalendarSyncCard();

  @override
  ConsumerState<_CalendarSyncCard> createState() =>
      _CalendarSyncCardState();
}

class _CalendarSyncCardState extends ConsumerState<_CalendarSyncCard> {
  bool _enabled = false;
  String? _calendarId;
  String? _calendarName;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    final enabled = sp.getBool('calendarSyncEnabled') ?? false;
    final calendarId = sp.getString('calendarSyncCalendarId');
    setState(() {
      _enabled = enabled;
      _calendarId = calendarId;
    });
  }

  Future<void> _toggleEnabled(bool v) async {
    setState(() => _enabled = v);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('calendarSyncEnabled', v);
    // 打开时自动建「倒班助手」日历，不弹「选日历」（用户 2026-10-25）。
    if (v && _calendarId == null) {
      final repo = ref.read(appRepositoryProvider);
      final service = CalendarSyncService(repo);
      final id = await service.ensureCalendar();
      if (id != null && mounted) {
        setState(() {
          _calendarId = id;
          _calendarName = CalendarSyncService.appCalendarName;
        });
      }
    }
  }

  Future<void> _pickCalendar() async {
    final repo = ref.read(appRepositoryProvider);
    final service = CalendarSyncService(repo);
    final calendars = await service.listCalendars();
    if (!mounted) return;

    if (calendars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.calendarSyncNoPermission)),
      );
      return;
    }

    await showGlassDialog<String?>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: L10n.calendarSyncPickCalendar,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(L10n.calendarSyncPickCalendarHint,
                style: AppTokens.rowSecondary),
            const SizedBox(height: 16),
            // 只读日历（如某些账户日历）写不进去，选它等于白同步 —— 过滤掉。
            // vivo 上本地日历与账户日历混在一起，用户容易选到只读的那个
            // 而 createEvent 静默失败、界面还提示「已同步」。
            for (final cal in calendars)
              if (!cal.readOnly)
                GlassPressable(
                  child: ListTile(
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: Text(cal.name),
                    onTap: () => Navigator.pop(dialogContext, cal.id),
                  ),
                ),
            if (calendars.every((c) => c.readOnly))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceMd),
                child: Text(L10n.calendarSyncNoWritable,
                    textAlign: TextAlign.center,
                    style: AppTokens.rowSecondary
                        .copyWith(color: AppTokens.inkMuted(context))),
              ),
          ],
        ),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(dialogContext, null),
            label: L10n.cancel,
          ),
        ],
      ),
    ).then((calendarId) {
      if (calendarId != null && mounted) {
        setState(() {
          _calendarId = calendarId;
          _calendarName = calendars
              .firstWhere((c) => c.id == calendarId, orElse: () => calendars.first)
              .name;
        });
        service.saveCalendarId(calendarId);
      }
    });
  }

  Future<void> _syncNow() async {
    if (!mounted) return;
    // 不弹「选日历」—— 自动创建一个「倒班助手」日历（用户 2026-10-25）。
    final repo = ref.read(appRepositoryProvider);
    final service = CalendarSyncService(repo);
    if (_calendarId == null) {
      final id = await service.ensureCalendar();
      if (id == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.calendarSyncNoPermission)),
          );
        }
        return;
      }
      if (mounted) setState(() => _calendarId = id);
    }
    setState(() => _syncing = true);
    try {
      final failed = await service.sync();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(failed > 0
                  ? L10n.calendarSyncPartial(failed)
                  : L10n.calendarSyncDone)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.calendarSyncFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassTile(
      translucentFill: false,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_outlined,
                    size: AppTokens.iconMd),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(L10n.calendarSync, style: AppTokens.labelStrong),
                      const SizedBox(height: AppTokens.gapHair),
                      Text(L10n.calendarSyncSubtitle,
                          style: AppTokens.rowSecondary),
                    ],
                  ),
                ),
                GlassSwitch(
                  value: _enabled,
                  onChanged: _toggleEnabled,
                ),
              ],
            ),
          ),
          if (_enabled) ...[
            const Divider(height: 1),
            GlassPressable(
              child: ListTile(
                leading: const Icon(Icons.calendar_view_day_outlined),
                title: Text(_calendarName ?? L10n.calendarSyncPickCalendar),
                trailing: const Icon(Icons.chevron_right_outlined),
                onTap: _pickCalendar,
              ),
            ),
            const Divider(height: 1),
            GlassPressable(
              child: ListTile(
                leading: _syncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_outlined),
                title: Text(L10n.calendarSyncSyncing),
                onTap: _syncing ? null : _syncNow,
              ),
            ),
            if (L10n.isEn || Platform.isAndroid) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(L10n.calendarSyncVivoHint,
                    style: AppTokens.rowSecondary),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 值班自动勿扰卡片：开 → 每个班次开始时切到优先勿扰、结束时恢复。
class _ShiftDndCard extends ConsumerStatefulWidget {
  const _ShiftDndCard();

  @override
  ConsumerState<_ShiftDndCard> createState() => _ShiftDndCardState();
}

class _ShiftDndCardState extends ConsumerState<_ShiftDndCard> {
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    final enabled = sp.getBool('dndEnabled') ?? false;
    if (!mounted) return;
    setState(() => _enabled = enabled);
  }

  Future<void> _toggleEnabled(bool v) async {
    if (v) {
      final granted = await AlarmService.checkDndPermission();
      if (!granted) {
        // vivo 等国产 ROM 的勿扰权限在系统设置里授；不回退开关会让「开着
        // 但到点不切」挂在那里没解释 —— 先授权限再开。
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.shiftDndNoPermission)),
        );
        await AlarmService.openDndSettings();
        return;
      }
    }
    if (!mounted) return;
    setState(() => _enabled = v);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('dndEnabled', v);
    // 开：重排时把未来 8 天的切换时刻排进去；关：清掉已排的切换事件。
    final repo = ref.read(appRepositoryProvider);
    await AlarmService.rescheduleAll(repo);
  }

  @override
  Widget build(BuildContext context) {
    return GlassTile(
      translucentFill: false,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.do_not_disturb_on_outlined,
                size: AppTokens.iconMd),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.shiftDnd, style: AppTokens.labelStrong),
                  const SizedBox(height: AppTokens.gapHair),
                  Text(L10n.shiftDndSubtitle, style: AppTokens.rowSecondary),
                ],
              ),
            ),
            GlassSwitch(
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
          ],
        ),
      ),
    );
  }
}