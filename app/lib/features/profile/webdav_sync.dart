// WebDAV 云备份的同步逻辑。
//
// 配置（服务器 / 账号 / 远程目录）存 prefs，**密码存 flutter_secure_storage**
// （Android 走 Keystore 加密）—— 凭据不进 prefs、更不进备份文件。
//
// 同步判定（用户方案 §四的落地）：
//  · 「本机变没变」= 当前导出的指纹 vs 上次同步时记下的指纹（`fnv1a64Hex`）；
//  · 「云端变没变」= 云端文件的 Last-Modified vs 上次同步时记下的值；
//  · 两边都没变 → 无事；一边变了 → 自动同步那一边；两边都变了 →
//    先比内容（可能只是同一份改动的两次导出），真冲突才弹窗让用户选边，
//    **被覆盖的一边先存一份 `backup-conflict-*.json` 到网盘**。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_info.dart';
import '../../core/webdav/webdav_client.dart';
import '../../data/app_repository.dart';
import '../../data/backup.dart';

/// prefs 里的配置键。
const String _kServer = 'webdavServer';
const String _kUser = 'webdavUser';
const String _kDir = 'webdavDir';
const String _kAutoSync = 'webdavAutoSync';
const String _kLastHash = 'webdavLastSyncHash';
const String _kLastMtime = 'webdavLastSyncMtime';
const String _kLastAt = 'webdavLastSyncAt';

/// 密码在安全存储里的键。
const String kWebdavPasswordKey = 'webdavPassword';

/// 常见网盘的预设地址（快捷配置：用户只填账号和应用密码）。
const List<(String, String)> kWebdavPresets = [
  ('坚果云', 'https://dav.jianguoyun.com/dav/'),
  ('InfiniCloud', 'https://dav.infini-cloud.net/dav/'),
];

/// WebDAV 配置（prefs 里的非敏感部分）。
class WebDavConfig {
  const WebDavConfig({
    required this.server,
    required this.user,
    required this.dir,
    required this.autoSync,
  });

  factory WebDavConfig.fromPrefs(SharedPreferences sp) => WebDavConfig(
        server: sp.getString(_kServer) ?? '',
        user: sp.getString(_kUser) ?? '',
        dir: sp.getString(_kDir) ?? '/倒班助手Pro/',
        autoSync: sp.getBool(_kAutoSync) ?? false,
      );

  final String server;
  final String user;
  final String dir;
  final bool autoSync;

  /// 配齐了才能同步（密码是另一路，运行时再查）。
  bool get isConfigured => server.trim().isNotEmpty && user.trim().isNotEmpty;

  Future<void> saveTo(SharedPreferences sp) async {
    await sp.setString(_kServer, server.trim());
    await sp.setString(_kUser, user.trim());
    await sp.setString(_kDir, dir.trim().isEmpty ? '/倒班助手Pro/' : dir.trim());
    await sp.setBool(_kAutoSync, autoSync);
  }
}

/// 同步状态（上次同步的时间与两边的指纹 / mtime），读显给用户看。
DateTime? lastSyncAt(SharedPreferences sp) {
  final v = sp.getInt(_kLastAt);
  return v == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(v);
}

/// 密码的存取口。生产走 flutter_secure_storage；测试用内存实现。
abstract class PasswordStore {
  Future<String?> read();
  Future<void> write(String? value);
}

/// 生产实现：flutter_secure_storage（Android 走 Keystore 加密，密钥不出系统）。
class SecurePasswordStore implements PasswordStore {
  const SecurePasswordStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read() => _storage.read(key: kWebdavPasswordKey);

  @override
  Future<void> write(String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: kWebdavPasswordKey);
    } else {
      await _storage.write(key: kWebdavPasswordKey, value: value);
    }
  }
}

/// 同步结果。
enum WebDavSyncOutcome {
  uploaded,
  downloaded,
  noChange,
  conflict,
  notConfigured,
  error,
}

class WebDavSyncResult {
  const WebDavSyncResult(this.outcome, [this.error]);

  final WebDavSyncOutcome outcome;

  /// 错误分档（`ok == false` 时非空）：
  ///  · `'auth'`               —— 401/403，账号或应用密码不对；
  ///  · `'network:dns'`        —— 域名解析失败，服务器地址写错；
  ///  · `'network:tls'`        —— TLS 握手失败，证书链或代理重签；
  ///  · `'network:timeout'`    —— 链路慢或代理黑洞，20 秒内没响应；
  ///  · `'network:other'`      —— 连接被拒 / 重置 / 代理拒绝等；
  ///  · `'http:NNN'`           —— 服务端返回了非 2xx（除 401/403）；
  ///  · `'other:TypeName'`     —— 其他未预期的异常。
  ///
  /// 以前是 `Object?` 只按 `== 'auth'` 二分，任何网络失败都归成「连不上服务器」
  /// —— 用户从这句话里推不出哪一类，排查无从下手。收档成字符串，UI 才能分档报。
  final String? error;

  bool get ok =>
      outcome == WebDavSyncOutcome.uploaded ||
      outcome == WebDavSyncOutcome.downloaded ||
      outcome == WebDavSyncOutcome.noChange;
}

/// 用户在冲突弹层里的选择。
enum ConflictChoice { keepLocal, keepRemote }

class WebDavSync {
  WebDavSync({required this.passwords});

  /// 生产传 [SecurePasswordStore]；测试传内存实现。
  final PasswordStore passwords;

  /// 跑一次同步。
  ///
  /// [onConflict] 给 null（启动自动同步）时，冲突直接返回
  /// [WebDavSyncOutcome.conflict]、什么都不动 —— 自动路径绝不替用户选边。
  /// [afterRestore] 在「云端覆盖本地」之后跑（外观重载、重复待办生成、
  /// 重排闹钟）；自动同步也可能走到它，所以由调用方注入同一套链。
  Future<WebDavSyncResult> run({
    required AppDatabase db,
    required SharedPreferences sp,
    Future<ConflictChoice?> Function()? onConflict,
    Future<void> Function()? afterRestore,
  }) async {
    final config = WebDavConfig.fromPrefs(sp);
    if (!config.isConfigured) {
      return const WebDavSyncResult(WebDavSyncOutcome.notConfigured);
    }
    final password = await passwords.read();
    if (password == null || password.isEmpty) {
      return const WebDavSyncResult(WebDavSyncOutcome.notConfigured);
    }

    final client = WebDavClient(
      baseUrl: config.server,
      user: config.user,
      password: password,
    );
    final dirNoSlash = config.dir.endsWith('/')
        ? config.dir.substring(0, config.dir.length - 1)
        : config.dir;
    final remotePath = '$dirNoSlash/$kBackupFileName';

    try {
      final local = await buildBackupJson(db, prefs: sp, appVersion: appVersion);
      final localHash = fnv1a64Hex(_fingerprint(local));
      final lastHash = sp.getString(_kLastHash);
      final lastMtime = sp.getInt(_kLastMtime);

      final remote = await client.stat(remotePath);
      final remoteMtime = remote?.lastModified.millisecondsSinceEpoch;
      final localChanged = lastHash != localHash;
      final remoteChanged =
          remote != null && remoteMtime != null && remoteMtime != lastMtime;

      if (remote == null) {
        await client.ensureDir(config.dir);
        await client.put(remotePath, local);
        await _mark(sp, localHash,
            remoteMtimeOf: await _mtimeOf(client, remotePath));
        return const WebDavSyncResult(WebDavSyncOutcome.uploaded);
      }

      if (!localChanged && !remoteChanged) {
        return const WebDavSyncResult(WebDavSyncOutcome.noChange);
      }

      if (remoteChanged && !localChanged) {
        await _restoreFrom(client, remotePath, db, sp, afterRestore);
        await _mark(sp, sp.getString(_kLastHash) ?? localHash,
            remoteMtimeOf: await _mtimeOf(client, remotePath));
        return const WebDavSyncResult(WebDavSyncOutcome.downloaded);
      }

      if (localChanged && !remoteChanged) {
        await client.ensureDir(config.dir);
        await client.put(remotePath, local);
        await _mark(sp, localHash,
            remoteMtimeOf: await _mtimeOf(client, remotePath));
        return const WebDavSyncResult(WebDavSyncOutcome.uploaded);
      }

      // 两边都变了：先比内容 —— 指纹相同就是同一份东西（比如另一台设备
      // 刚推过一模一样的数据），不算冲突。
      final remoteBody = await client.get(remotePath);
      if (fnv1a64Hex(_fingerprint(remoteBody)) == localHash) {
        await _mark(sp, localHash, remoteMtimeOf: remoteMtime);
        return const WebDavSyncResult(WebDavSyncOutcome.noChange);
      }

      final choice = await onConflict?.call();
      if (choice == null) {
        return const WebDavSyncResult(WebDavSyncOutcome.conflict);
      }

      // 被覆盖的一边先在网盘上留底：谁输谁进 backup-conflict-*。
      final now = DateTime.now();
      final stamp = '${now.year}${_two(now.month)}${_two(now.day)}'
          '-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final conflictPath = '$dirNoSlash/backup-conflict-$stamp.json';
      if (choice == ConflictChoice.keepLocal) {
        // 云端那份是输家：先把它存底，再上传本地。
        await client.put(conflictPath, remoteBody);
        await client.ensureDir(config.dir);
        await client.put(remotePath, local);
        await _mark(sp, localHash,
            remoteMtimeOf: await _mtimeOf(client, remotePath));
        return const WebDavSyncResult(WebDavSyncOutcome.uploaded);
      } else {
        // 本地这份是输家：把它存到网盘，再让云端那份下来。
        await client.put(conflictPath, local);
        await _restoreFrom(client, remotePath, db, sp, afterRestore);
        await _mark(sp, fnv1a64Hex(_fingerprint(remoteBody)),
            remoteMtimeOf: await _mtimeOf(client, remotePath));
        return const WebDavSyncResult(WebDavSyncOutcome.downloaded);
      }
    } on WebDavAuthException {
      return const WebDavSyncResult(WebDavSyncOutcome.error, 'auth');
    } on WebDavNotFoundException {
      return const WebDavSyncResult(WebDavSyncOutcome.error, 'notfound');
    } on WebDavNetworkException catch (e) {
      return WebDavSyncResult(WebDavSyncOutcome.error,
          'network:${e.kind.name}');
    } on WebDavException catch (e) {
      final status = e.status ?? -1;
      return WebDavSyncResult(WebDavSyncOutcome.error, 'http:$status');
    } catch (e) {
      return WebDavSyncResult(WebDavSyncOutcome.error,
          'other:${e.runtimeType}');
    } finally {
      client.close();
    }
  }

  Future<void> _restoreFrom(
    WebDavClient client,
    String remotePath,
    AppDatabase db,
    SharedPreferences sp,
    Future<void> Function()? afterRestore,
  ) async {
    final body = await client.get(remotePath);
    final parsed = parseBackupJson(
      body,
      currentSchemaVersion: db.schemaVersion,
    );
    await restoreParsedBackup(db, parsed.tables);
    await restoreBackupPrefs(sp, parsed.prefs);
    await afterRestore?.call();
    // 恢复后本机内容与云端那份一致：指纹按**云端那份**记（重导出的 JSON 可能
    // 与它有键序差异，用本机重算的指纹会把「刚恢复」误判成「又有本地改动」）。
    await sp.setString(_kLastHash, fnv1a64Hex(_fingerprint(body)));
  }

  /// 同步指纹用的规范化：把 `exportedAt`（每次导出都变的时间戳）归零。
  ///
  /// 不做这一步，「本机变没变」永远为真 —— 两次导出除了这一个字段全都一样，
  /// 哈希却不同。本地导出与云端文件两边都过这同一条，比较才有意义。
  String _fingerprint(String backup) => backup.replaceAllMapped(
        RegExp(r'"exportedAt":\s*\d+'),
        (_) => '"exportedAt":0',
      );

  Future<int?> _mtimeOf(WebDavClient client, String remotePath) async {
    final item = await client.stat(remotePath);
    return item?.lastModified.millisecondsSinceEpoch;
  }

  Future<void> _mark(
    SharedPreferences sp,
    String hash, {
    required int? remoteMtimeOf,
  }) async {
    await sp.setString(_kLastHash, hash);
    if (remoteMtimeOf != null) {
      await sp.setInt(_kLastMtime, remoteMtimeOf);
    }
    await sp.setInt(_kLastAt, DateTime.now().millisecondsSinceEpoch);
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 启动自动同步：只在「开了开关且配置齐全」时跑一次；冲突不弹窗（等手动），
/// 网络失败静默 —— 启动路径不该为它阻塞，也不该在没让用户选边的情况下改数据。
///
/// 返回 null = 没跑（未配置 / 未开启）；否则是结果，调用方可用于提示。
Future<WebDavSyncResult?> maybeAutoSync(
  AppDatabase db,
  SharedPreferences sp, {
  required WebDavSync sync,
  required Future<void> Function()? afterRestore,
}) async {
  final config = WebDavConfig.fromPrefs(sp);
  if (!config.autoSync || !config.isConfigured) return null;
  return sync.run(db: db, sp: sp, afterRestore: afterRestore);
}
