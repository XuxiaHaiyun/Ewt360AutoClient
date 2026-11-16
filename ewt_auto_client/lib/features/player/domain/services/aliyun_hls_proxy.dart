/// 阿里云私有加密 HLS 的本地透明解密代理：在 127.0.0.1 起 HTTP 服务对播放器
/// 伪装成普通 HLS 源，分片经 SceTsSampleDecryptor 解密后边下边播，支持 seek。
/// 供播放页以 proxy.playlistUrl 覆盖原 CDN 地址后交给 media_kit。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '_sce_ts_decryptor.dart';
import 'video_source_resolver.dart';

/// 阿里云私有加密 HLS 的**本地透明解密代理**
///
/// ## 为什么需要它
///
/// 私有加密是**样本级加密**: TS 容器明文, 但每个 PES 负载被 AES-128-ECB 加密
/// (详见 [SceTsSampleDecryptor])。mpv/ffmpeg 没有"解 PES 负载"这类滤镜, 所以
/// 直接把 CDN 地址交给 media_kit 只能得到乱码画面 —— 这就是之前"阿里云加密线路
/// 无法实时播放"的根因。
///
/// 本类在 127.0.0.1 上起一个 HTTP 服务, 对 mpv 伪装成一个普通 HLS 源:
///
/// ```text
/// mpv ──GET /0/playlist.m3u8──▶ 代理 ──GET 原m3u8(带 Origin/Referer)──▶ CDN
///    ◀── 已删除诱饵 KEY 行、分片指向本代理的 m3u8 ──┤
/// mpv ──GET /0/seg/12.ts──────▶ 代理 ──GET 原分片──▶ CDN
///    ◀── SceTsSampleDecryptor 解密后的明文 TS ──────┘
/// ```
///
/// 于是实现**边下边播**(无需等整片下载), 且天然支持拖动/seek —— mpv 只会在
/// 需要时请求对应分片。
///
/// ## 用法
///
/// ```dart
/// final proxy = await AliyunHlsProxy.start(
///   qualities: source.qualities,
///   headers: resolver.dlHeaders,
/// );
/// // 用 proxy.playlistUrl 与 proxy.qualities 覆盖原 URL 后交给播放器
/// ...
/// await proxy.stop();   // 播放页关闭时
/// ```
class AliyunHlsProxy {
  final HttpServer _server;
  final Dio _dio;
  final Map<String, String> _headers;
  final List<_ProxyQuality> _qualities;
  final int _maxCachedSegments;

  /// 已解密分片的 LRU 缓存 (key = '<档位>/<序号>')
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();

  /// 正在拉取中的分片 (避免 mpv 并发请求同一段时重复下载)
  final Map<String, Future<Uint8List>> _inflight = {};

  AliyunHlsProxy._({
    required HttpServer server,
    required Dio dio,
    required Map<String, String> headers,
    required List<_ProxyQuality> qualities,
    required int maxCachedSegments,
  })  : _server = server,
        _dio = dio,
        _headers = headers,
        _qualities = qualities,
        _maxCachedSegments = maxCachedSegments;

  /// 启动代理
  ///
  /// [qualities] 需携带 `keyBase64` (16 字节 `_vpk`); 无密钥的档位会被跳过
  /// (不加密的流可直接播, 无需代理)。
  /// [headers] 拉 CDN 用的 Origin/Referer/UA, 可用
  /// [VideoSourceResolver.dlHeaders]。
  /// [maxCachedSegments] 已解密分片的缓存上限 (LRU), 控制内存占用。
  static Future<AliyunHlsProxy> start({
    required List<ResolvedVideoQuality> qualities,
    required Map<String, String> headers,
    Dio? dio,
    int maxCachedSegments = 24,
  }) async {
    final client = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(minutes: 2),
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ));

    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    final prefix = (int qIndex) => 'http://127.0.0.1:${server.port}/$qIndex';

    // 逐个清晰度拉取并重写播放列表 (串行避免瞬时并发打满 CDN)
    final loaded = <_ProxyQuality>[];
    try {
      for (final q in qualities) {
        final keyB64 = q.keyBase64;
        if (keyB64 == null || keyB64.isEmpty) continue;
        Uint8List keyBytes;
        try {
          keyBytes = Uint8List.fromList(base64.decode(keyB64));
        } catch (_) {
          continue;
        }
        if (keyBytes.length != 16) continue;

        final text = await _fetchText(client, q.url, headers);
        if (text == null) continue;
        final index = loaded.length;
        loaded.add(_ProxyQuality(
          index: index,
          label: q.label,
          keyBase64: keyB64,
          key: keyBytes,
          playlist: rewritePlaylist(
            playlist: text,
            baseUrl: q.url,
            proxyPrefix: prefix(index),
          ).playlist,
          segments: _segmentsOf(text, q.url),
        ));
      }
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }

    if (loaded.isEmpty) {
      await server.close(force: true);
      throw StateError('阿里云私有加密: 没有任何可代理的清晰度档位');
    }

    final ready = AliyunHlsProxy._(
      server: server,
      dio: client,
      headers: headers,
      qualities: loaded,
      maxCachedSegments: maxCachedSegments,
    );
    ready._serve();
    return ready;
  }

  /// 本地播放列表地址 (默认第一档)
  String get playlistUrl => urlFor(0);

  /// 指定档位的本地播放列表地址
  String urlFor(int index) {
    final i = index.clamp(0, _qualities.length - 1);
    return 'http://127.0.0.1:${_server.port}/$i/playlist.m3u8';
  }

  /// 代理端口 (调试用)
  int get port => _server.port;

  /// 已重写为本地地址的清晰度列表 (可直接替换原 qualities 交给播放器,
  /// 这样切换清晰度同样走代理)
  List<ResolvedVideoQuality> get qualities => [
        for (var i = 0; i < _qualities.length; i++)
          ResolvedVideoQuality(
            label: _qualities[i].label,
            url: urlFor(i),
            keyBase64: _qualities[i].keyBase64,
          ),
      ];

  /// 停止代理并释放缓存
  Future<void> stop() async {
    _cache.clear();
    _inflight.clear();
    try {
      await _server.close(force: true);
    } catch (_) {}
  }

  // ─── 请求处理 ───

  void _serve() {
    _server.listen(
      (HttpRequest request) {
        unawaited(_handle(request));
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path; // 形如 /0/playlist.m3u8 或 /0/seg/12.ts
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    try {
      if (parts.length < 2) {
        return _respond(request, 404, 'not found');
      }
      final qIndex = int.tryParse(parts[0]);
      if (qIndex == null || qIndex < 0 || qIndex >= _qualities.length) {
        return _respond(request, 404, 'unknown quality');
      }
      final q = _qualities[qIndex];

      if (parts[1] == 'playlist.m3u8') {
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        return _respond(request, 200, q.playlist);
      }

      if (parts[1] == 'seg' && parts.length >= 3) {
        final segIndex = int.tryParse(parts[2].replaceAll('.ts', ''));
        if (segIndex == null || segIndex < 0 || segIndex >= q.segments.length) {
          return _respond(request, 404, 'unknown segment');
        }
        final bytes = await _getSegment(q, segIndex);
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
        request.response.headers.set(HttpHeaders.cacheControlHeader, 'max-age=3600');
        request.response.add(bytes);
        await request.response.close();
        return;
      }
      return _respond(request, 404, 'not found');
    } catch (e) {
      return _respond(request, 500, 'proxy error: $e');
    }
  }

  /// 取已解密分片 (缓存 → 去重并发 → 拉取)
  Future<Uint8List> _getSegment(_ProxyQuality q, int index) async {
    final cacheKey = '${q.index}/$index';
    final hit = _cache.remove(cacheKey);
    if (hit != null) {
      _cache[cacheKey] = hit; // 重新插到末尾维持 LRU
      return hit;
    }
    final pending = _inflight[cacheKey];
    if (pending != null) return pending;

    final future = _fetchAndDecrypt(q, index);
    _inflight[cacheKey] = future;
    try {
      final bytes = await future;
      _cache[cacheKey] = bytes;
      while (_cache.length > _maxCachedSegments) {
        _cache.remove(_cache.keys.first);
      }
      return bytes;
    } finally {
      _inflight.remove(cacheKey);
    }
  }

  Future<Uint8List> _fetchAndDecrypt(_ProxyQuality q, int index) async {
    final resp = await _dio.get<List<int>>(
      q.segments[index],
      options: Options(headers: _headers),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) {
      throw StateError('分片 ${q.index}/$index 下载为空');
    }
    return SceTsSampleDecryptor.decryptTs(Uint8List.fromList(data), q.key);
  }

  static void _respond(HttpRequest request, int status, String body) {
    request.response.statusCode = status;
    request.response.write(body);
    unawaited(request.response.close().catchError((_) {}));
  }

  static Future<String?> _fetchText(
    Dio dio,
    String url,
    Map<String, String> headers,
  ) async {
    try {
      final resp = await dio.get<List<int>>(
        url,
        options: Options(headers: headers),
      );
      final data = resp.data;
      if (data == null || data.isEmpty) return null;
      return utf8.decode(data, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // ─── m3u8 重写 (纯函数, 离线可测) ───

  /// 把远端 m3u8 重写为"分片指向本代理"的版本
  ///
  /// - 删除 `#EXT-X-KEY` 行 (私有加密的诱饵, 整段并不加密);
  /// - 分片行替换为 `<proxyPrefix>/seg/<序号>.ts`;
  /// - 返回的 `segments` 为分片的**原始绝对 URL**, 顺序与序号一一对应。
  static PlaylistRewrite rewritePlaylist({
    required String playlist,
    required String baseUrl,
    required String proxyPrefix,
  }) {
    Uri? base = Uri.tryParse(baseUrl);
    final segments = <String>[];
    final out = <String>[];
    for (final rawLine in playlist.split('\n')) {
      var line = rawLine;
      final t = line.trim();
      if (t.startsWith('#EXT-X-KEY')) {
        continue; // 丢弃诱饵
      }
      if (t.isNotEmpty && !t.startsWith('#')) {
        final absolute =
            base == null ? t : base.resolve(t).toString();
        // 嵌套 m3u8 不改写 (交给调用方递归), 只处理分片
        line = '$proxyPrefix/seg/${segments.length}.ts';
        segments.add(absolute);
      }
      out.add(line);
    }
    return PlaylistRewrite(playlist: out.join('\n'), segments: segments);
  }

  /// 抓出分片绝对 URL (不改写), 供 [_ProxyQuality] 使用
  static List<String> _segmentsOf(String playlist, String baseUrl) {
    return rewritePlaylist(
      playlist: playlist,
      baseUrl: baseUrl,
      proxyPrefix: '',
    ).segments;
  }

}

/// [AliyunHlsProxy.rewritePlaylist] 的结果
class PlaylistRewrite {
  /// 重写后的 m3u8 文本
  final String playlist;

  /// 分片的原始绝对 URL, 顺序与 `seg/<序号>.ts` 对应
  final List<String> segments;

  const PlaylistRewrite({required this.playlist, required this.segments});
}

/// 代理内部维护的单个清晰度档位
class _ProxyQuality {
  final int index;
  final Uint8List key;
  final String playlist;
  final List<String> segments;
  final String label;
  final String? keyBase64;

  const _ProxyQuality({
    required this.index,
    required this.key,
    required this.playlist,
    required this.segments,
    this.label = '',
    this.keyBase64,
  });
}
