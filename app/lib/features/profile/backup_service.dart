import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_info.dart';
import '../../core/l10n.dart';
import '../../core/widgets/glass_action_button.dart';
import '../../core/widgets/glass_dialog.dart';
import '../../core/widgets/glass_snackbar.dart';
import '../../data/backup.dart';
import '../../data/app_repository.dart';
import '../../domain/shift_rotation.dart';
import '../../state/app_settings.dart';
import '../../state/nav_settings.dart';
import '../alarm/alarm_service.dart';

/// 导入导出的编排：文件选择走 SAF（原生通道），编码 / 校验 / 恢复走
/// `data/backup.dart`。
///
/// 通道与铃声那一组共用 `com.daoban.shiftassistantpro/settings` —— 它就是
/// 「设置相关的杂项原生能力」那条通道，为两个方法再开一条新通道没有收益。
class BackupService {
  BackupService._();

  static const _settingsChannel = MethodChannel(
      'com.daoban.shiftassistantpro/settings');

  /// 「我的 → 数据 → 导出数据」：建一个 JSON 备份文件（用户选位置）。
  ///
  /// 文件名带日期：同一天多导几次也不会在下载目录里互相覆盖。
  static Future<void> exportData(BuildContext context, WidgetRef ref) async {
    final sp = await SharedPreferences.getInstance();
    final db = ref.read(databaseProvider);
    String content;
    try {
      content = await buildBackupJson(db, prefs: sp, appVersion: appVersion);
    } catch (_) {
      if (context.mounted) {
        showGlassSnack(context, L10n.exportFailed, icon: Icons.error_outline);
      }
      return;
    }
    final now = DateTime.now();
    final name =
        'daoban-backup-${now.year}${_two(now.month)}${_two(now.day)}.json';
    bool ok;
    try {
      ok = await _settingsChannel.invokeMethod<bool>('createBackupFile',
              {'name': name, 'content': content}) ??
          false;
    } on PlatformException {
      ok = false;
    }
    if (!context.mounted) return;
    showGlassSnack(
      context,
      ok == true ? L10n.exportDone(name) : L10n.exportFailed,
      icon: ok == true ? Icons.check_circle_outlined : Icons.error_outline,
    );
  }

  /// 「我的 → 数据 → 导入数据」：挑一个备份文件 → 确认 → 覆盖恢复。
  static Future<void> importData(BuildContext context, WidgetRef ref) async {
    String? path;
    try {
      path = await _settingsChannel.invokeMethod<String>('pickBackupFile');
    } on PlatformException {
      path = null;
    }
    // null = 用户取消，不是错误。
    if (path == null || !context.mounted) return;

    final sp = await SharedPreferences.getInstance();
    final db = ref.read(databaseProvider);
    final repo = ref.read(appRepositoryProvider);

    final text = await File(path).readAsString();
    if (!context.mounted) return;
    final parsed = await _parseSafely(context, text, db.schemaVersion);
    if (parsed == null || !context.mounted) return;

    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: L10n.importConfirmTitle,
        content: Text(L10n.importConfirmContent),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            label: L10n.cancel,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            variant: GlassActionVariant.danger,
            onPressed: () => Navigator.pop(dialogContext, true),
            label: L10n.importData,
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await restoreParsedBackup(db, parsed.tables);
      await restoreBackupPrefs(sp, parsed.prefs);
      // 外观那一组在内存里的值要跟着 prefs 走一遍（主题 / 主色 / 语言 / 档位）。
      await ref.read(appSettingsProvider.notifier).reload();
      await ref.read(navSettingsProvider.notifier).reload();
      // 重复待办「当前这一次」的生成与归档裁剪：备份里可能带着系列定义，
      // 让列表立刻长出该有的那几条，而不是等下次启动。
      await repo.advanceRecurringTodos(today: dateOnly(DateTime.now()));
      await repo.pruneArchivedTodos();
      // 原生侧已排的闹钟按恢复后的数据重排 —— 与「改排班结构必须重排」
      // 同一条规矩，只是这里换的是整套数据。
      await AlarmService.rescheduleAll(repo);
    } catch (_) {
      if (context.mounted) {
        showGlassSnack(context, L10n.importFailed, icon: Icons.error_outline);
      }
      return;
    }
    if (context.mounted) {
      showGlassSnack(context, L10n.importDone,
          icon: Icons.check_circle_outlined);
    }
  }

  /// 解析 + 格式校验；失败时把原因说给用户（不是一句笼统的「失败」）。
  static Future<
      ({Map<String, List<Map<String, dynamic>>> tables,
              Map<String, Object?> prefs})?
      > _parseSafely(BuildContext context, String text, int schemaVersion) async {
    try {
      return parseBackupJson(text, currentSchemaVersion: schemaVersion);
    } on BackupTooNewException catch (e) {
      if (context.mounted) {
        showGlassSnack(
            context, L10n.importVersionTooNew('${e.backupVersion}'),
            icon: Icons.error_outline);
      }
    } on BackupFormatException {
      if (context.mounted) {
        showGlassSnack(context, L10n.importInvalidFile,
            icon: Icons.error_outline);
      }
    }
    return null;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
