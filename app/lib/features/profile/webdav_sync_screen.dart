import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/design_tokens.dart';
import '../../core/glass/glass.dart';
import '../../core/haptics.dart';
import '../../core/l10n.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/centered_content.dart';
import '../../core/widgets/glass_action_button.dart';
import '../../core/widgets/glass_button.dart';
import '../../core/widgets/glass_dialog.dart';
import '../../core/widgets/glass_field.dart';
import '../../core/widgets/glass_input.dart';
import '../../core/widgets/glass_pressable.dart';
import '../../core/widgets/glass_snackbar.dart';
import '../../core/widgets/glass_switch.dart';
import '../../data/app_repository.dart';
import '../../state/app_settings.dart';
import '../../state/nav_settings.dart';
import '../alarm/alarm_service.dart';
import 'webdav_sync.dart';

/// WebDAV 云备份的设置页：配置账号 → 立即同步。
///
/// 数据的编排全在 [WebDavSync]（可脱离界面跑，启动自动同步走同一条）；本页
/// 只负责收集四个字段、把结果说给人听。
class WebDavSyncScreen extends ConsumerStatefulWidget {
  const WebDavSyncScreen({super.key});

  @override
  ConsumerState<WebDavSyncScreen> createState() => _WebDavSyncScreenState();
}

class _WebDavSyncScreenState extends ConsumerState<WebDavSyncScreen> {
  final _serverCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();
  bool _autoSync = false;

  bool _loading = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final config = WebDavConfig.fromPrefs(sp);
    final password = await const SecurePasswordStore().read();
    if (!mounted) return;
    setState(() {
      _serverCtrl.text = config.server;
      _userCtrl.text = config.user;
      _passwordCtrl.text = password ?? '';
      _dirCtrl.text = config.dir;
      _autoSync = config.autoSync;
      _loading = false;
    });
  }

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  WebDavConfig _configFromFields() => WebDavConfig(
        server: _serverCtrl.text,
        user: _userCtrl.text,
        dir: _dirCtrl.text,
        autoSync: _autoSync,
      );

  Future<void> _save() async {
    final config = _configFromFields();
    await config.saveTo(await _prefs());
    await const SecurePasswordStore().write(_passwordCtrl.text.trim());
    Haptics.commit();
    if (mounted) {
      showGlassSnack(context, L10n.webdavConfigSaved,
          icon: Icons.check_circle_outlined);
    }
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    final config = _configFromFields();
    if (!config.isConfigured ||
        _serverCtrl.text.trim().isEmpty ||
        _passwordCtrl.text.trim().isEmpty) {
      showGlassSnack(context, L10n.webdavNotConfigured,
          icon: Icons.error_outline);
      return;
    }
    // 先保存再同步：改了字段直接点同步，落库的应当是界面上这份。
    await _save();
    if (!mounted) return;
    setState(() => _syncing = true);
    final result = await WebDavSync(passwords: const SecurePasswordStore()).run(
      db: ref.read(databaseProvider),
      sp: await _prefs(),
      onConflict: _askConflict,
      afterRestore: _afterRestore,
    );
    if (!mounted) return;
    setState(() => _syncing = false);
    _showResult(result);
  }

  /// 云端覆盖本地之后的链路，与「导入数据」同一条（外观重载 → 重复待办生成
  /// → 重排闹钟）。
  Future<void> _afterRestore() async {
    await ref.read(appSettingsProvider.notifier).reload();
    await ref.read(navSettingsProvider.notifier).reload();
    final repo = ref.read(appRepositoryProvider);
    final now = DateTime.now();
    await repo.advanceRecurringTodos(
        today: DateTime.utc(now.year, now.month, now.day));
    await repo.pruneArchivedTodos();
    await AlarmService.rescheduleAll(repo);
  }

  /// 冲突弹层。返回 null = 用户取消（同步原地不动）。
  Future<ConflictChoice?> _askConflict() async {
    if (!mounted) return null;
    return showGlassDialog<ConflictChoice>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        title: L10n.webdavConflictTitle,
        content: Text(L10n.webdavConflictContent),
        actions: [
          GlassActionButton(
            onPressed: () => Navigator.pop(dialogContext),
            label: L10n.cancel,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () =>
                Navigator.pop(dialogContext, ConflictChoice.keepRemote),
            label: L10n.webdavKeepRemote,
          ),
          const SizedBox(width: 8),
          GlassActionButton(
            onPressed: () =>
                Navigator.pop(dialogContext, ConflictChoice.keepLocal),
            label: L10n.webdavKeepLocal,
          ),
        ],
      ),
    );
  }

  void _showResult(WebDavSyncResult result) {
    final msg = switch (result.outcome) {
      WebDavSyncOutcome.uploaded => L10n.webdavSyncedUp,
      WebDavSyncOutcome.downloaded => L10n.webdavSyncedDown,
      WebDavSyncOutcome.noChange => L10n.webdavNoChange,
      WebDavSyncOutcome.conflict => L10n.webdavConflictTitle,
      WebDavSyncOutcome.notConfigured => L10n.webdavNotConfigured,
      WebDavSyncOutcome.error => _errorMessage(result.error),
    };
    showGlassSnack(
      context,
      msg,
      icon: result.ok
          ? Icons.check_circle_outlined
          : Icons.error_outline,
    );
  }

  /// 把 [WebDavSyncResult.error] 里的分档字符串翻成用户能读懂的话。
  ///
  /// 以前只按 `== 'auth'` 二分，其他全归成一句「连不上服务器」—— 用户推不出
  /// 是地址错、证书被拦、超时还是服务器拒绝，排查无从下手。现在按前缀分：
  /// `network:dns` / `network:tls` / `network:timeout` / `http:NNN` /
  /// `other:TypeName`，每种都有自己那句。
  String _errorMessage(String? error) {
    if (error == null || error.isEmpty) return L10n.webdavConnFailed;
    final sep = error.indexOf(':');
    final kind = sep < 0 ? error : error.substring(0, sep);
    final arg = sep < 0 ? error : error.substring(sep + 1);
    switch (kind) {
      case 'auth':
        return L10n.webdavAuthFailed;
      case 'network':
        switch (arg) {
          case 'dns':
            return L10n.webdavDnsFailed;
          case 'tls':
            return L10n.webdavTlsFailed;
          case 'timeout':
            return L10n.webdavTimeout;
          default:
            return L10n.webdavConnFailed;
        }
      case 'http':
        final code = int.tryParse(arg);
        return code == null
            ? L10n.webdavConnFailed
            : L10n.webdavServerRejected(code);
      default:
        // 'notfound' / 'other:...' / 其他未预期的分档 → 旧兵「连不上服务器」，
        // 保证任何异常都能给用户一句、而不是空提示。
        return L10n.webdavConnFailed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = AppTokens.inkMuted(context);
    return Scaffold(
      body: SafeArea(
        child: CenteredContent(
          child: _loading
              ? const SizedBox()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    Row(
                      children: [
                        _backButton(context),
                        const SizedBox(width: AppTokens.spaceSm),
                        Expanded(
                          child: Text(L10n.webdavTitle,
                              style: AppTokens.pageTitle),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                    Text(
                      L10n.webdavIntro,
                      style:
                          AppTokens.rowSecondary.copyWith(color: muted),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),
                    // 快捷配置：两颗预设填服务器地址，账号密码自己填。
                    Row(
                      children: [
                        for (var i = 0; i < kWebdavPresets.length; i++) ...[
                          if (i > 0) const SizedBox(width: AppTokens.spaceSm),
                          Expanded(
                            child: _presetChip(
                              context,
                              label: kWebdavPresets[i].$1,
                              url: kWebdavPresets[i].$2,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppTokens.spaceMd),
                    GlassTile(
                      translucentFill: false,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GlassField(
                            label: L10n.webdavServer,
                            child: TextField(
                              controller: _serverCtrl,
                              keyboardType: TextInputType.url,
                              decoration: glassInputDecoration(context)
                                  .copyWith(hintText: L10n.webdavServerHint),
                            ),
                          ),
                          const SizedBox(height: AppTokens.spaceMd),
                          GlassField(
                            label: L10n.webdavUser,
                            child: TextField(
                              controller: _userCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration:
                                  glassInputDecoration(context),
                            ),
                          ),
                          const SizedBox(height: AppTokens.spaceMd),
                          GlassField(
                            label: L10n.webdavPassword,
                            child: TextField(
                              controller: _passwordCtrl,
                              obscureText: true,
                              decoration:
                                  glassInputDecoration(context),
                            ),
                          ),
                          const SizedBox(height: AppTokens.spaceXs),
                          Text(
                            L10n.webdavPasswordHint,
                            style: AppTokens.microText
                                .copyWith(color: muted),
                          ),
                          const SizedBox(height: AppTokens.spaceMd),
                          GlassField(
                            label: L10n.webdavDir,
                            child: TextField(
                              controller: _dirCtrl,
                              decoration: glassInputDecoration(context)
                                  .copyWith(hintText: L10n.webdavDirHint),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),
                    GlassTile(
                      translucentFill: false,
                      padding: EdgeInsets.zero,
                      child: GlassPressable(
                        child: ListTile(
                          title: Text(L10n.webdavAutoSync),
                          subtitle: Text(
                            L10n.webdavAutoSyncHint,
                            maxLines: 3,
                          ),
                          trailing: GlassSwitch(
                            value: _autoSync,
                            onChanged: (v) {
                              Haptics.select();
                              setState(() => _autoSync = v);
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceLg),
                    _syncButton(context),
                    const SizedBox(height: AppTokens.spaceSm),
                    _lastSyncLabel(context),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _backButton(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassPressable(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).maybePop(),
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
          child: const AppIcon(
            Icons.arrow_back_outlined,
            size: AppTokens.iconLg,
          ),
        ),
      ),
    );
  }

  Widget _presetChip(BuildContext context,
      {required String label, required String url}) {
    return GlassPressable(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Haptics.select();
          setState(() => _serverCtrl.text = url);
        },
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.radiusL),
            border: Border.all(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.45)),
            color: Theme.of(context)
                .colorScheme
                .primary
                .withValues(alpha: 0.10),
          ),
          child: Text(
            label,
            maxLines: 1,
            style: AppTokens.labelSecondary.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _syncButton(BuildContext context) {
    return GlassButton(
      primary: true,
      onPressed: _syncing ? null : _syncNow,
      icon: _syncing
          ? const SizedBox(
              width: AppTokens.iconSm,
              height: AppTokens.iconSm,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.cloud_sync_outlined, color: Colors.white),
      child: Text(
        _syncing ? L10n.webdavSyncing : L10n.webdavSyncNow,
        maxLines: 1,
        style: AppTokens.labelStrong.copyWith(color: Colors.white),
      ),
    );
  }

  Widget _lastSyncLabel(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: _prefs(),
      builder: (context, snap) {
        final at = snap.data == null ? null : lastSyncAt(snap.data!);
        final text = at == null
            ? L10n.webdavNeverSynced
            : L10n.webdavLastSync(
                DateFormat('yyyy-MM-dd HH:mm').format(at));
        return Center(
          child: Text(
            text,
            maxLines: 1,
            style: AppTokens.microText
                .copyWith(color: AppTokens.inkMuted(context)),
          ),
        );
      },
    );
  }
}
