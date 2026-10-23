// 极小 WebDAV 客户端：PROPFIND / GET / PUT / MKCOL 四个动作，够「把一个备份
// 文件放进网盘、再取回来」。
//
// 为什么不引 `webdav_client` 包：全仓库的 HTTP 都走 `dart:io` 的 `HttpClient`
// （`update_checker.dart` 同一条路），为一个备份文件引入一整个依赖树不值当 ——
// WebDAV 的读写本质上就是「带 Basic 认证的 HTTP 动词 + 一段 XML 属性」，自己写
// 反而把超时、错误码、编码全部握在手里。
//
// 两点协议现实（都实测过坚果云 / InfiniCloud 的行为）：
//  · 属性前缀不统一：`<d:getlastmodified>`、`<D:getlastmodified>`、无前缀的
//    都有 —— 解析时剥掉前缀再认名字，别匹配完整标签。
//  · 目录要**逐级** MKCOL：`PUT /dav/倒班助手Pro/backup.json` 之前，
//    `/倒班助手Pro/` 这一级必须先建好（405 = 已存在，照成功处理）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 某个远程文件的身份（同步比对用）。
class WebDavItem {
  const WebDavItem({required this.lastModified, this.etag});

  final DateTime lastModified;
  final String? etag;
}

class WebDavException implements Exception {
  const WebDavException(this.message, {this.status, this.cause});
  final String message;
  final int? status;

  /// 网络层异常时指向底层的 `SocketException` / `HandshakeException` / 其他
  /// —— 保留它，方便把具体错误信息透到 UI 上（用户拿得到真实报错文本）。
  final Object? cause;

  @override
  String toString() => 'WebDavException($status): $message';
}

/// 401 / 403：账号或应用密码不对。
class WebDavAuthException extends WebDavException {
  const WebDavAuthException({super.status}) : super('认证失败');
}

/// 404：远程还没有这个文件（首次同步的正常状态，不算错误）。
class WebDavNotFoundException extends WebDavException {
  const WebDavNotFoundException() : super('远程不存在', status: 404);
}

/// 网络层的失败分档。用户从「连不上服务器」这句话里永远推不出是哪一类，
/// 分档之后 UI 能把话讲清楚：地址错、证书被拦、请求超时、还是别的。
enum WebDavNetworkKind {
  /// DNS 解析失败：地址写错、域名不存在。
  dns,

  /// TLS 握手失败：证书链不全、被企业代理重签、系统 CA 不含签发者。
  tls,

  /// 请求超时：链路慢、代理黑洞、服务端未响应。
  timeout,

  /// 其他：连接被拒、连接重置、代理拒绝、未知 socket 错误。
  other,
}

/// 网络层失败（区别于 HTTP 层非 2xx）。
///
/// HTTP 层错误走 [WebDavException] 且带 `status`；这里的场景是**根本没拿到
/// HTTP 响应**，用户看到的必须是「连不上」这一类，且能区分是哪种。
class WebDavNetworkException extends WebDavException {
  const WebDavNetworkException(
    this.kind,
    String message, {
    required super.cause,
  }) : super(message);

  final WebDavNetworkKind kind;

  @override
  String toString() => 'WebDavNetworkException(${kind.name}): '
      '${cause?.toString() ?? 'network error'}';
}

/// 把 `SocketException` / `HandshakeException` / `TimeoutException` 归到
/// [WebDavNetworkKind]。关键字来自 Android / iOS 的 socket 层报错文本，
/// 拿不准就归到 `other`，不瞎分。
WebDavNetworkKind classifyNetworkError(Object e) {
  final msg = e.toString().toLowerCase();
  if (e is TimeoutException) return WebDavNetworkKind.timeout;
  if (e is HandshakeException) return WebDavNetworkKind.tls;
  if (e is SocketException || e is HttpException || e is TlsException) {
    if (msg.contains('certificate') ||
        msg.contains('ssl') ||
        msg.contains('tls') ||
        msg.contains('handshake') ||
        msg.contains('x509')) {
      return WebDavNetworkKind.tls;
    }
    if (msg.contains('getsocketinfo') ||
        msg.contains('name or service not known') ||
        msg.contains('getaddrinfo') ||
        msg.contains('unknown name') ||
        msg.contains('no route to host') ||
        msg.contains('网络不可达')) {
      return WebDavNetworkKind.dns;
    }
  }
  return WebDavNetworkKind.other;
}

class WebDavClient {
  WebDavClient({
    required this.baseUrl,
    required this.user,
    required this.password,
  });

  /// 服务根地址，如 `https://dav.jianguoyun.com/dav/`。
  final String baseUrl;
  final String user;
  final String password;

  static const _timeout = Duration(seconds: 20);

  HttpClient? _client;

  HttpClient get _http {
    final c = _client ??= HttpClient()
      ..connectionTimeout = _timeout
      ..autoUncompress = true;
    return c;
  }

  /// 远程相对路径 → 完整 URI。**逐段编码**：目录名带中文 / 空格是常态
  /// （默认目录就叫「倒班助手Pro」），整串 parse 会把非法字符留在路径里。
  Uri resolve(String path) {
    final base = Uri.parse(baseUrl.trim());
    final segments = [
      ...base.path.split('/'),
      ...path.split('/'),
    ].where((s) => s.isNotEmpty).map(Uri.encodeComponent).toList();
    return base.replace(path: '/${segments.join('/')}');
  }

  HttpHeaders _auth(HttpHeaders headers) {
    final token = base64Encode(utf8.encode('$user:$password'));
    headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
    return headers;
  }

  Future<(int status, String body, HttpHeaders respHeaders)> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    try {
      final request = await _http.openUrl(method, uri);
      _auth(request.headers);
      headers?.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType =
            ContentType('application', 'octet-stream', charset: 'utf-8');
        request.add(utf8.encode(body as String));
      }
      final response =
          await request.close().timeout(_timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw WebDavAuthException(status: response.statusCode);
      }
      return (response.statusCode, text, response.headers);
    } on WebDavException {
      // 401/403 已经包装成 [WebDavAuthException]，直接抛。
      rethrow;
    } on TimeoutException catch (e) {
      throw WebDavNetworkException(
        WebDavNetworkKind.timeout,
        '连接超时（${_timeout.inSeconds} 秒未响应）',
        cause: e,
      );
    } on HandshakeException catch (e) {
      throw WebDavNetworkException(
          WebDavNetworkKind.tls, e.message, cause: e);
    } on TlsException catch (e) {
      throw WebDavNetworkException(
          classifyNetworkError(e), e.message, cause: e);
    } on SocketException catch (e) {
      throw WebDavNetworkException(
          classifyNetworkError(e), e.message, cause: e);
    } on HttpException catch (e) {
      throw WebDavNetworkException(
          classifyNetworkError(e), e.message, cause: e);
    }
  }

  /// 远程文件（或目录）的属性；404 → null。
  ///
  /// **409 也当不存在处理**：坚果云 WebDAV 对不存在的文件返 409 Conflict
  /// 而不是标准 404 —— 兼容层（见 jianguoyun WebDAV 兼容性 GitHub issue
  /// `qixing-jk/all-api-hub#633`），否则首次同步永远卡在「服务器拒返（HTTP 409）」。
  Future<WebDavItem?> stat(String path) async {
    final (status, body, _) = await _send(
      'PROPFIND',
      resolve(path),
      headers: {'Depth': '0'},
    );
    if (status == 404 || status == 409) return null;
    if (status < 200 || status >= 300) {
      throw WebDavException('PROPFIND 失败', status: status);
    }
    final modified = _extractTag(body, 'getlastmodified');
    if (modified == null) return null;
    DateTime parsed;
    try {
      parsed = HttpDate.parse(modified.trim()).toUtc();
    } on FormatException {
      return null;
    }
    return WebDavItem(
      lastModified: parsed,
      etag: _extractTag(body, 'getetag'),
    );
  }

  /// 逐级建目录（含末级）。405（已存在）/ 409（坚果云：已存在）照成功处理
  /// —— 这里的语义是「确保存在」。
  ///
  /// 409 一并当成功是因为坚果云对 MKCOL 已存在的目录返 409 而不是标准 405
  /// （anx-reader#410 同因）；若父目录真的不存在，下一步 PUT 会暴露。
  Future<void> ensureDir(String dirPath) async {
    final segments =
        dirPath.split('/').where((s) => s.isNotEmpty).toList();
    var built = '';
    for (final seg in segments) {
      built = '$built/$seg';
      final (status, _, _) = await _send('MKCOL', resolve(built));
      if (status != 405 && status != 409 && (status < 200 || status >= 300)) {
        throw WebDavException('MKCOL $built 失败', status: status);
      }
    }
  }

  /// 读远程文件；404 → [WebDavNotFoundException]。
  ///
  /// 409 也当不存在：坚果云对不存在的文件返 409 而不是标准 404。
  Future<String> get(String path) async {
    final (status, body, _) = await _send('GET', resolve(path));
    if (status == 404 || status == 409) throw const WebDavNotFoundException();
    if (status < 200 || status >= 300) {
      throw WebDavException('GET 失败', status: status);
    }
    return body;
  }

  /// 写远程文件。**目录必须已存在**（调用方先 [ensureDir]）——PUT 不自动建父目录。
  Future<void> put(String path, String content) async {
    final (status, _, _) = await _send('PUT', resolve(path), body: content);
    if (status < 200 || status >= 300) {
      throw WebDavException('PUT 失败', status: status);
    }
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// 从多状态 XML 里剥出一个属性值。前缀随意（d / D / lp1 / 无），只认名字；
  /// 多值时取第一个（Depth: 0 的响应里本来就只有一个）。
  static String? _extractTag(String xml, String name) {
    final pattern = RegExp(
      '<(?:[A-Za-z0-9]+:)?$name(?:\\s[^>]*)?>([^<]*)<',
      multiLine: true,
    );
    return pattern.firstMatch(xml)?.group(1);
  }
}

/// 本地内容指纹：FNV-1a 64 位。同步判「本机变没变」用 —— 与「上次同步过的
/// 那份」比对，而不是维护一个逐表递增的版本号（那个要插进每条写路径，漏一处
/// 就静默失效）。
String fnv1a64Hex(String s) {
  var hash = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    hash ^= b;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16);
}
