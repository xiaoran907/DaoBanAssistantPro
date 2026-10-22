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

import 'dart:convert';
import 'dart:io';

/// 某个远程文件的身份（同步比对用）。
class WebDavItem {
  const WebDavItem({required this.lastModified, this.etag});

  final DateTime lastModified;
  final String? etag;
}

class WebDavException implements Exception {
  const WebDavException(this.message, {this.status});
  final String message;
  final int? status;

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
  }

  /// 远程文件（或目录）的属性；404 → null。
  Future<WebDavItem?> stat(String path) async {
    final (status, body, _) = await _send(
      'PROPFIND',
      resolve(path),
      headers: {'Depth': '0'},
    );
    if (status == 404) return null;
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

  /// 逐级建目录（含末级）。405（已存在）照成功处理 —— 这里的语义是「确保存在」。
  Future<void> ensureDir(String dirPath) async {
    final segments =
        dirPath.split('/').where((s) => s.isNotEmpty).toList();
    var built = '';
    for (final seg in segments) {
      built = '$built/$seg';
      final (status, _, _) = await _send('MKCOL', resolve(built));
      if (status != 405 && (status < 200 || status >= 300)) {
        throw WebDavException('MKCOL $built 失败', status: status);
      }
    }
  }

  /// 读远程文件；404 → [WebDavNotFoundException]。
  Future<String> get(String path) async {
    final (status, body, _) = await _send('GET', resolve(path));
    if (status == 404) throw const WebDavNotFoundException();
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
