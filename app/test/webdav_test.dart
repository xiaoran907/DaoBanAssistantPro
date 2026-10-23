// app/test/webdav_test.dart
//
// WebDAV 两半：
//  ① `WebDavClient` —— 对着一块**真的 dart:io HttpServer**（进程内起、监听
//     127.0.0.1 随机端口）验请求的动词 / 头 / 路径编码，以及 401 / 404 的分支；
//  ② `WebDavSync` —— 同一台桩服务器上把四种同步路径各走一遍：
//     云端没有 → 上传；只云端新 → 恢复；只本机新 → 上传；两边都变 →
//     冲突（自动路径不选边；手动路径按选择走、输的一边在网盘留底）。
//
// 密码不落 prefs：配置在 SharedPreferences（mock），密码用内存 PasswordStore。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiftassistantpro/core/webdav/webdav_client.dart';
import 'package:shiftassistantpro/data/app_repository.dart';
import 'package:shiftassistantpro/data/backup.dart';
import 'package:shiftassistantpro/domain/payroll.dart';
import 'package:shiftassistantpro/features/profile/webdav_sync.dart';

/// 进程内 WebDAV 桩：只认路径 `/dav/...`，把每个请求记下来。
class _StubDavServer {
  final HttpServer _server;
  final List<({String method, String path, String? auth, String? body})>
      requests = [];

  /// 远程文件（key = 完整路径，已解码）。**mtime 在 PUT 时定格**：PROPFIND
  /// 每次回同一个值，只有再次 PUT（另一台设备覆盖）才会变 —— 与真服务器一致。
  final Map<String, ({String body, DateTime mtime})> files = {};
  final Set<String> dirs = {};

  String? forcedRealm; // 非空时要求 Basic 认证（账号 u / 密码 correct-pass）
  int? forcedStatus;   // 非空时所有请求都强制返回该 HTTP 状态（优先于其他分支）

  /// 模拟坚果云 WebDAV：不存在的文件返 409 而不是标准 404（PROPFIND / GET），
  /// MKCOL 已存在的目录返 409 而不是 405 —— 客户端必须能把这些 409 当兼容
  /// 处理，否则首次同步就卡死（见 jianguoyun WebDAV 兼容性 GitHub issue）。
  bool jianguoyunLike = false;

  _StubDavServer._(this._server);

  static Future<_StubDavServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _StubDavServer._(server);
    server.listen(stub._handle);
    return stub;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/dav/';

  Future<void> close() => _server.close(force: true);

  int get putCount => requests
      .where((r) => r.method == 'PUT' && r.path.endsWith(kBackupFileName))
      .length;

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    requests.add((
      method: req.method,
      path: Uri.decodeComponent(req.uri.path),
      auth: req.headers.value(HttpHeaders.authorizationHeader),
      body: body.isEmpty ? null : body,
    ));

    if (forcedRealm != null) {
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      if (basicOf(auth) != 'u:correct-pass') {
        req.response.statusCode = 401;
        req.response.headers
            .set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="x"');
        await req.response.close();
        return;
      }
    }

    if (forcedStatus != null) {
      req.response.statusCode = forcedStatus!;
      await req.response.close();
      return;
    }

    final path = Uri.decodeComponent(req.uri.path);
    switch (req.method) {
      case 'PROPFIND':
        final f = files[path];
        if (f != null || dirs.contains(path)) {
          final lastMod = HttpDate.format(
              (f?.mtime ?? DateTime.now()).toUtc());
          req.response.statusCode = 207;
          req.response.write('<d:multistatus xmlns:d="DAV:">'
              '<d:response><d:propstat><d:prop>'
              '<d:getlastmodified>$lastMod</d:getlastmodified>'
              '</d:prop></d:propstat></d:response></d:multistatus>');
        } else {
          // 坚果云不存在的文件返 409，不是 404 —— 客户端得兼容。
          req.response.statusCode = jianguoyunLike ? 409 : 404;
        }
      case 'GET':
        final f = files[path];
        if (f == null) {
          req.response.statusCode = jianguoyunLike ? 409 : 404;
        } else {
          req.response.write(f.body);
        }
      case 'PUT':
        files[path] = (body: body, mtime: DateTime.now());
      case 'MKCOL':
        if (files.containsKey(path) || dirs.contains(path)) {
          req.response.statusCode = jianguoyunLike ? 409 : 405;
        } else {
          dirs.add(path);
        }
      default:
        req.response.statusCode = 405;
    }
    await req.response.close();
  }

  String? basicOf(String? auth) {
    if (auth == null || !auth.startsWith('Basic ')) return null;
    return utf8.decode(base64Decode(auth.substring(6)));
  }

  /// 测试用：模拟「另一台设备」直接往云端放一份内容（mtime 明确往后推，
  /// 与本机那几次 PUT 拉开 —— 真场景里本来就隔着几分钟 / 几天）。
  void putRemote(String path, String body) {
    files[path] = (
      body: body,
      mtime: DateTime.now().add(const Duration(minutes: 5)),
    );
  }
}

/// 内存 PasswordStore。
class _MemPasswords implements PasswordStore {
  String? value = 'app-pass';
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? v) async { value = v; }
}

void main() {
  late _StubDavServer dav;

  setUp(() async => dav = await _StubDavServer.start());
  tearDown(() => dav.close());

  group('WebDavClient', () {
    test('PUT 带认证头、路径逐段编码（中文目录）', () async {
      final client = WebDavClient(
        baseUrl: dav.baseUrl,
        user: 'user@example.com',
        password: 'app-pass',
      );
      await client.ensureDir('/倒班助手Pro');
      await client.put('/倒班助手Pro/$kBackupFileName', '{"x":1}');

      final put = dav.requests.lastWhere((r) => r.method == 'PUT');
      expect(dav.basicOf(put.auth), 'user@example.com:app-pass');
      expect(put.path, '/dav/倒班助手Pro/$kBackupFileName');
      expect(put.body, '{"x":1}');
    });

    test('stat 读回 Last-Modified；不存在的文件返回 null', () async {
      final client =
          WebDavClient(baseUrl: dav.baseUrl, user: 'u', password: 'p');
      await client.put('/f.json', 'x');
      final item = await client.stat('/f.json');
      expect(item, isNotNull);

      expect(await client.stat('/missing.json'), isNull);
    });

    test('401 → WebDavAuthException；GET 不存在的文件 → NotFound', () async {
      final client =
          WebDavClient(baseUrl: dav.baseUrl, user: 'u', password: 'wrong');
      dav.forcedRealm = 'dav';

      await expectLater(
          client.stat('/f.json'), throwsA(isA<WebDavAuthException>()));

      dav.forcedRealm = null;
      await expectLater(client.get('/missing.json'),
          throwsA(isA<WebDavNotFoundException>()));
    });

    test('fnv1a64Hex 同输入同输出、异输入异输出', () {
      expect(fnv1a64Hex('abc'), fnv1a64Hex('abc'));
      expect(fnv1a64Hex('abc'), isNot(fnv1a64Hex('abd')));
    });

    test('非 2xx 非 401/403 → WebDavException 带 status', () async {
      dav.forcedStatus = 400;
      final client =
          WebDavClient(baseUrl: dav.baseUrl, user: 'u', password: 'p');
      await expectLater(
        client.stat('/f.json'),
        throwsA(
          isA<WebDavException>().having((e) => e.status, 'status', 400),
        ),
      );
    });

    test('连接被拒（无服务器）→ WebDavNetworkException(kind: other)', () async {
      // 端口 1 在 Linux / Android 上永远无监听，稳定触发 Connection refused。
      final client = WebDavClient(
        baseUrl: 'http://127.0.0.1:1/dav/',
        user: 'u',
        password: 'p',
      );
      await expectLater(
        client.stat('/f.json'),
        throwsA(
          isA<WebDavNetworkException>()
              .having((e) => e.kind, 'kind', WebDavNetworkKind.other),
        ),
      );
    });

    test('坚果云兼容：不存在的文件返 409 → stat 返 null、ensureDir 不抛', () async {
      dav.jianguoyunLike = true;
      final client = WebDavClient(
        baseUrl: dav.baseUrl, user: 'u', password: 'p');
      // 不存在的文件 → stat 不抛异常、返 null（坚果云返 409，不当错误）。
      expect(await client.stat('/nope.json'), isNull);
      // MKCOL 到不存在的目录 → 创建成功（无异常）。
      await client.ensureDir('/newdir');
      // MKCOL 到已存在的目录 → 坚果云返 409，当成功。
      await client.ensureDir('/newdir');
    });
  });

  group('WebDavSync', () {
    late AppDatabase db;
    late AppRepository repo;
    late SharedPreferences sp;
    late String remotePath;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = AppRepository(db);
      await repo.ensureSeeded();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      sp = await SharedPreferences.getInstance();
      await WebDavConfig(
        server: dav.baseUrl,
        user: 'user@example.com',
        dir: '/倒班助手Pro',
        autoSync: false,
      ).saveTo(sp);
      remotePath = '/dav/倒班助手Pro/$kBackupFileName';
    });

    tearDown(() => db.close());

    Future<WebDavSyncResult> run({
      Future<ConflictChoice?> Function()? onConflict,
      Future<void> Function()? afterRestore,
    }) =>
        WebDavSync(passwords: _MemPasswords()).run(
          db: db,
          sp: sp,
          onConflict: onConflict,
          afterRestore: afterRestore,
        );

    test('未配置 / 没密码：不跑', () async {
      await const WebDavConfig(server: '', user: '', dir: '/x', autoSync: false)
          .saveTo(sp);
      expect((await run()).outcome, WebDavSyncOutcome.notConfigured);

      await WebDavConfig(
              server: dav.baseUrl, user: 'u', dir: '/x', autoSync: false)
          .saveTo(sp);
      expect(
        (await WebDavSync(passwords: _MemPasswords()..value = null)
                .run(db: db, sp: sp))
            .outcome,
        WebDavSyncOutcome.notConfigured,
      );
    });

    test('云端没有文件 → 上传（先建目录），并记下指纹与时间', () async {
      final result = await run();
      expect(result.outcome, WebDavSyncOutcome.uploaded);

      expect(dav.dirs.contains('/dav/倒班助手Pro'), isTrue,
          reason: '目录逐级 MKCOL');
      final remote = dav.files[remotePath]?.body;
      expect(remote, isNotNull);
      final parsed = parseBackupJson(remote!,
          currentSchemaVersion: db.schemaVersion);
      expect(parsed.tables['shift_schedule_rows'], isNotEmpty);
      expect(sp.getString('webdavLastSyncHash'), isNotNull);
      expect(sp.getInt('webdavLastSyncAt'), isNotNull);
    });

    test('两边都没变 → noChange，不重复写云端', () async {
      await run();
      final putsBefore = dav.putCount;
      expect((await run()).outcome, WebDavSyncOutcome.noChange);
      expect(dav.putCount, putsBefore, reason: '没变化就不该再写云端');
    });

    test('只云端变了（另一台设备推过）→ 云端那份恢复到本地', () async {
      await run(); // 初次上传

      // 另一台设备：第二块库，改了薪资设置后整库导出、推上云端。
      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      final repo2 = AppRepository(db2);
      await repo2.ensureSeeded();
      await repo2.setPayrollConfig(const PayrollConfig(monthlyWage: 999));
      dav.putRemote(remotePath,
          await buildBackupJson(db2, prefs: sp, appVersion: '0.12.2'));

      final result = await run();
      expect(result.outcome, WebDavSyncOutcome.downloaded);
      expect((await repo.getPayrollConfig()).monthlyWage, 999,
          reason: '云端那份落进了本地库');
    });

    test('只本机变了 → 上传', () async {
      await run();
      await repo.setPayrollConfig(const PayrollConfig(monthlyWage: 320));
      final result = await run();
      expect(result.outcome, WebDavSyncOutcome.uploaded);
      expect(dav.files[remotePath]!.body.contains('payroll_settings_rows'), isTrue);
    });

    test('两边都变：自动路径不选边；手动保留本地会先把云端那份留底', () async {
      await run(); // 初次上传

      // 云端换成另一台设备推的不同数据，本机也改一笔 → 两边都变。
      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      final repo2 = AppRepository(db2);
      await repo2.ensureSeeded();
      dav.putRemote(remotePath,
          await buildBackupJson(db2, prefs: sp, appVersion: '0.12.2'));
      await repo.setPayrollConfig(const PayrollConfig(monthlyWage: 320));

      // 自动路径：冲突原样返回，云端与本机都没被动。
      final auto = await run();
      expect(auto.outcome, WebDavSyncOutcome.conflict);
      expect(dav.files.keys.where((k) => k.contains('backup-conflict-')),
          isEmpty, reason: '没选边就不该动任何一边');

      // 手动：保留本地 —— 云端那份先存底，再上传本地。
      final manual =
          await run(onConflict: () async => ConflictChoice.keepLocal);
      expect(manual.outcome, WebDavSyncOutcome.uploaded);
      final conflicts = dav.files.keys
          .where((k) => k.contains('backup-conflict-'))
          .toList();
      expect(conflicts, hasLength(1));
      final backed = dav.files[conflicts.single]!.body;
      expect(
        parseBackupJson(backed, currentSchemaVersion: db.schemaVersion),
        isNotNull,
        reason: '留底的是一份完整的备份',
      );
    });

    test('连不上服务器 → error，分档为 network:other', () async {
      await const WebDavConfig(
        server: 'http://127.0.0.1:1/dav/',
        user: 'u',
        dir: '/x',
        autoSync: false,
      ).saveTo(sp);
      final result = await WebDavSync(passwords: _MemPasswords())
          .run(db: db, sp: sp);
      expect(result.outcome, WebDavSyncOutcome.error);
      expect(result.error, 'network:other',
          reason: '连接被拒归 other —— 用户看到「连不上服务器」那句');
    });

    test('服务器拒返（HTTP 400）→ error，分档为 http:400', () async {
      dav.forcedStatus = 400;
      final result = await WebDavSync(passwords: _MemPasswords())
          .run(db: db, sp: sp);
      expect(result.outcome, WebDavSyncOutcome.error);
      expect(result.error, 'http:400',
          reason: 'HTTP 层非 2xx 带状态码 —— UI 直接报「服务器拒返（HTTP 400）」');
    });

    test('坚果云兼容：首次上传在 409 兼容处理下能跑通', () async {
      dav.jianguoyunLike = true;
      // PROPFIND 返 409（当作不存在）、MKCOL 返 201 创建成功、PUT 写回。
      final first = await WebDavSync(passwords: _MemPasswords())
          .run(db: db, sp: sp);
      expect(first.outcome, WebDavSyncOutcome.uploaded,
          reason: '坚果云 409 不再卡在首次上传（以前报「服务器拒返（HTTP 409）」）');
      expect(dav.files[remotePath], isNotNull);
      // 第二次同步：PROPFIND 返 207，无变化。
      final second = await WebDavSync(passwords: _MemPasswords())
          .run(db: db, sp: sp);
      expect(second.outcome, WebDavSyncOutcome.noChange);
    });
  });
}
