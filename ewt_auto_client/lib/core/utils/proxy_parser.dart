/// 代理解析工具 (支持 http / socks5 / socks5h)
///
/// 供代理设置弹窗 (TXT 导入) 与网络层 (DioClient 代理适配) 共用。
///
/// 支持的代理格式:
/// - `host:port` — 无前缀, 默认按 HTTP 代理处理
/// - `http://host:port` / `https://host:port` — HTTP 代理
/// - `socks5://host:port` — SOCKS5 代理 (DNS 在本地解析)
/// - `socks5h://host:port` — SOCKS5 代理 (DNS 交给代理远端解析)
library;

/// 代理协议类型
enum ProxyScheme {
  /// HTTP 代理 (含显式 http:// / https:// 与无前缀写法)
  http,

  /// SOCKS5 代理: 域名在本地解析后再交给代理
  socks5,

  /// SOCKS5h 代理: 域名直接发给代理, 由代理端解析 (防 DNS 污染)
  socks5h,
}

/// 解析后的代理规格
class ProxySpec {
  const ProxySpec(this.scheme, this.host, this.port);

  final ProxyScheme scheme;
  final String host;
  final int port;

  /// 展示/持久化字符串: socks 系列保留前缀, http 不带前缀 (向后兼容)
  String toDisplayString() {
    switch (scheme) {
      case ProxyScheme.http:
        return '$host:$port';
      case ProxyScheme.socks5:
        return 'socks5://$host:$port';
      case ProxyScheme.socks5h:
        return 'socks5h://$host:$port';
    }
  }
}

final RegExp _schemePrefixRe =
    RegExp(r'^(socks5h|socks5|https?):\/\/(.+)$', caseSensitive: false);

final RegExp _hostRe = RegExp(r'^[0-9a-zA-Z._\-]+$');

/// 解析单条代理为 [ProxySpec]
///
/// 支持 `host:port` / `http(s)://host:port` / `socks5://host:port` /
/// `socks5h://host:port`; 无前缀默认按 [ProxyScheme.http] 处理。
/// 非法输入返回 null。
ProxySpec? parseProxySpec(String raw) {
  var s = raw.trim();
  var scheme = ProxyScheme.http;
  final m = _schemePrefixRe.firstMatch(s);
  if (m != null) {
    scheme = switch (m.group(1)!.toLowerCase()) {
      'socks5' => ProxyScheme.socks5,
      'socks5h' => ProxyScheme.socks5h,
      _ => ProxyScheme.http,
    };
    s = m.group(2)!;
  }

  // 去掉路径部分 (容忍 http://host:port/path 这类输入)
  final slash = s.indexOf('/');
  if (slash >= 0) s = s.substring(0, slash);

  final colon = s.lastIndexOf(':');
  if (colon <= 0 || colon == s.length - 1) return null;
  final host = s.substring(0, colon).trim();
  final port = int.tryParse(s.substring(colon + 1).trim()) ?? 0;
  if (host.isEmpty || !_hostRe.hasMatch(host)) return null;
  if (port <= 0 || port > 65535) return null;
  return ProxySpec(scheme, host, port);
}

/// 解析 TXT 内容为去重后的代理列表
///
/// 支持每行一个代理 (`host:port` / `http://host:port` / `socks5://host:port`
/// / `socks5h://host:port`), 以 `#`/`//` 开头视为注释,
/// 自动去重并保持原顺序。
List<String> parseProxyLines(String content) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in content.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
      continue;
    }
    final normalized = normalizeProxy(line);
    if (normalized != null && seen.add(normalized)) {
      result.add(normalized);
    }
  }
  return result;
}

/// 规范化单条代理
///
/// HTTP 代理输出 `host:port` (剥掉前缀); socks 代理输出
/// `socks5://host:port` / `socks5h://host:port` (保留前缀以区分协议)。
/// 非法输入返回 null。
String? normalizeProxy(String line) {
  return parseProxySpec(line)?.toDisplayString();
}

/// 解析代理字符串为 (host, port)
///
/// 支持格式:
/// - `127.0.0.1:8080`
/// - `proxy.example.com:3128`
/// - `http://127.0.0.1:8080` (自动剥掉 scheme)
/// - `socks5://127.0.0.1:1080` / `socks5h://127.0.0.1:1080`
/// 非法格式返回 (空串, 0)。
(String, int) parseProxyHostPort(String raw) {
  final spec = parseProxySpec(raw);
  if (spec == null) return ('', 0);
  return (spec.host, spec.port);
}
