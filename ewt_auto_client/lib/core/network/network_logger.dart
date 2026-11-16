/// 网络日志: 单例写入器 (原生写 network.log 文件带轮转, Web 输出控制台,
/// 内存队列批量落盘) + 统一拦截器 (记录请求/响应, 二进制仅记字节数, 敏感字段脱敏)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 网络日志写入器
///
/// - 原生平台 (Windows/Android/macOS/Linux): 写入 Download/EwtAutoClient/logs/network.log
/// - Web 平台: 输出到浏览器控制台 (F12 → Console)
///
/// 支持动态开关，关闭时不写入任何内容。
///
/// 性能说明: 日志先进入内存队列, 由 [Timer] 每 ~1s 批量异步落盘,
/// 避免在 Dio 拦截器 (主 isolate) 中同步文件 IO 拖慢请求。
class NetworkLogger {
  NetworkLogger._();
  static final NetworkLogger instance = NetworkLogger._();

  bool _enabled = false;
  bool _initialized = false;
  io.File? _logFile;

  /// 待落盘日志队列 (异步批量写, 见 [_writeRaw]/[_flush])
  final List<String> _queue = [];

  /// 批量落盘定时器 (懒启动, 每次 [_writeRaw] 后重置)
  Timer? _flushTimer;

  /// 批量落盘间隔
  static const _flushInterval = Duration(milliseconds: 1000);

  /// 队列上限: 防止异常高频请求导致内存膨胀, 达到上限立即强制落盘
  static const _maxQueueSize = 2000;

  /// 单文件大小上限 (超过后轮转为 network.log.1)
  static const _maxLogSizeBytes = 5 * 1024 * 1024;

  /// 当前是否启用
  bool get enabled => _enabled;

  /// 日志输出目标描述
  String? get logFilePath {
    if (!_enabled) return null;
    if (kIsWeb) return '浏览器控制台 (F12 → Console)';
    return _logFile?.path;
  }

  /// 设置开关
  void setEnabled(bool value) {
    _enabled = value;
    if (value && !_initialized) {
      _init();
    }
    // 关闭时立即落盘剩余日志, 避免关闭后数据丢失
    if (!value) {
      _flush();
    }
  }

  /// 初始化
  Future<void> _init() async {
    if (_initialized) return;

    if (kIsWeb) {
      _initialized = true;
      _writeRaw('═══════════════════════════════════════');
      _writeRaw('  网络日志启动 ${DateTime.now().toString().substring(0, 19)}');
      _writeRaw('═══════════════════════════════════════');
      return;
    }

    // 原生平台：写入文件 (Download/EwtAutoClient/logs/network.log)
    try {
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final logDir = io.Directory(p.join(dir.path, 'EwtAutoClient', 'logs'));
      if (!logDir.existsSync()) {
        logDir.createSync(recursive: true);
      }
      _logFile = io.File(p.join(logDir.path, 'network.log'));
      _initialized = true;

      _writeRaw('═══════════════════════════════════════');
      _writeRaw('  网络日志启动 ${DateTime.now().toString().substring(0, 19)}');
      _writeRaw('═══════════════════════════════════════');
    } catch (_) {
      // 初始化失败不阻断主流程
    }
  }

  /// 写入一条日志 (入队, 由定时器批量落盘, 不阻塞调用方)
  void log(String message) {
    if (!_enabled) return;
    if (!_initialized) {
      _init();
      return;
    }
    _writeRaw(message);
  }

  void _writeRaw(String line) {
    if (kIsWeb) {
      // ignore: avoid_print
      print('[NET] $line');
      return;
    }
    _queue.add(line);
    // 队列满立即落盘 (防御性, 正常情况由定时器批量写)
    if (_queue.length >= _maxQueueSize) {
      _flush();
      return;
    }
    // 懒启动批量落盘定时器
    _flushTimer ??= Timer(_flushInterval, _flush);
  }

  /// 将队列中的日志批量追加到文件 (异步, 主 isolate 不阻塞)
  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_queue.isEmpty) return;
    final lines = List<String>.from(_queue);
    _queue.clear();
    try {
      // 日志轮转: 超过上限时归档为 network.log.1 再写入新文件
      final file = _logFile;
      if (file != null && await file.exists() &&
          await file.length() > _maxLogSizeBytes) {
        final archive = io.File('${file.path}.1');
        try {
          await archive.writeAsBytes(await file.readAsBytes(), flush: true);
          await file.writeAsString('', flush: true);
        } catch (_) {
          // 归档失败不阻断日志写入
        }
      }
      await file?.writeAsString(
        '${lines.join('\n')}\n',
        mode: io.FileMode.append,
      );
    } catch (_) {}
  }

  /// 清空日志 (先落盘队列中未写入的日志, 再清空文件)
  void clear() {
    if (kIsWeb) return;
    _flush();
    try {
      if (_logFile?.existsSync() == true) {
        _logFile!.writeAsStringSync('');
      }
    } catch (_) {}
  }

  /// 为任意 Dio 实例附加统一网络日志拦截器。
  ///
  /// 幂等：不会重复添加。适用于主 [DioClient] 之外独立创建的 Dio
  /// （如腾讯云/阿里云 VOD 解析、验证码网关、视频下载等）。
  static void attach(Dio dio, {bool logBody = true}) {
    if (dio.interceptors.whereType<NetworkLogInterceptor>().isEmpty) {
      dio.interceptors.add(NetworkLogInterceptor(logBody: logBody));
    }
  }
}

/// 统一网络日志拦截器
///
/// 同时适用于主 [DioClient] 与独立的外部 Dio（腾讯云/阿里云 VOD、验证码等）。
///
/// 与 Dio 自带 [LogInterceptor] 不同，本拦截器对二进制响应（视频/TS/DRM key）
/// 仅记录字节数，避免日志文件被二进制数据撑爆；小体积（≤64KB）的二进制响应
/// （如 VOD 接口返回的 JSON）会被按 UTF-8 文本预览。
///
/// 日志格式: `[HH:mm:ss.SSS][#requestId] →/←/✕ METHOD URL (耗时ms 大小)`
/// 敏感字段 (token/password/secret/sign/authorization 等) 在预览时脱敏。
class NetworkLogInterceptor extends Interceptor {
  final bool logBody;

  NetworkLogInterceptor({this.logBody = true});

  /// 全局递增请求序号 (跨所有 Dio 实例唯一, 便于关联请求-响应)
  static int _requestSeq = 0;

  /// 当前时间戳 (HH:mm:ss.SSS)
  static String _ts() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${three(now.millisecond)}';
  }

  /// 供测试/工具复用的脱敏入口 (见 [_mask])
  static dynamic debugMask(dynamic value) => _mask(value);

  /// 供测试复用的时间戳格式入口 (见 [_ts])
  static String debugTimestamp() => _ts();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final log = NetworkLogger.instance;
    if (!log.enabled) return handler.next(options);
    final reqId = ++_requestSeq;
    options.extra['_netReqId'] = reqId;
    options.extra['_netStartMs'] = DateTime.now().millisecondsSinceEpoch;
    log.log('[$_ts()][#$reqId] → ${options.method} ${options.uri}');
    if (logBody) {
      final body = _bodyPreview(options.data);
      if (body != null) log.log('[$_ts()][#$reqId]   请求体: $body');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final log = NetworkLogger.instance;
    if (!log.enabled) return handler.next(response);
    final reqId = response.requestOptions.extra['_netReqId'] as int? ?? 0;
    final startMs = response.requestOptions.extra['_netStartMs'] as int?;
    final elapsed = startMs == null
        ? ''
        : ' (${DateTime.now().millisecondsSinceEpoch - startMs}ms)';
    final size = _byteLength(response.data);
    final sizeStr = size != null && size > 0 ? ' ${_formatBytes(size)}' : '';
    log.log(
      '[$_ts()][#$reqId] ← ${response.statusCode ?? 0} '
      '${response.requestOptions.method} ${response.requestOptions.uri}'
      '$sizeStr$elapsed',
    );
    if (logBody) {
      final body = _bodyPreview(response.data);
      if (body != null) log.log('[$_ts()][#$reqId]   响应体: $body');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final log = NetworkLogger.instance;
    if (!log.enabled) return handler.next(err);
    final reqId = err.requestOptions.extra['_netReqId'] as int? ?? 0;
    final startMs = err.requestOptions.extra['_netStartMs'] as int?;
    final elapsed = startMs == null
        ? ''
        : ' (${DateTime.now().millisecondsSinceEpoch - startMs}ms)';
    final status = err.response?.statusCode;
    log.log(
      '[$_ts()][#$reqId] ✕ ${status ?? '-'} ${err.requestOptions.method} '
      '${err.requestOptions.uri} 错误: ${err.type} ${err.message ?? ''}$elapsed',
    );
    handler.next(err);
  }

  /// 敏感字段 key 匹配规则 (命中则脱敏)
  static final RegExp _sensitiveKey = RegExp(
    r'token|password|passwd|secret|sign|authorization|captcha',
    caseSensitive: false,
  );

  /// 将请求/响应体转为可预览文本；二进制大体积返回 null（不预览）。
  ///
  /// Map/JSON 中的敏感字段 (token/password/secret 等) 会脱敏为 `***`。
  static String? _bodyPreview(dynamic data) {
    if (data == null) return null;
    if (data is String) {
      // 尝试按 JSON 解析 (若为 JSON 字符串, 解析后脱敏再序列化)
      final trimmed = data.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          final decoded = jsonDecode(trimmed);
          return _truncate(jsonEncode(_mask(decoded)));
        } catch (_) {
          // 非 JSON 字符串直接返回
        }
      }
      final s = data.trim();
      return s.isEmpty ? null : _truncate(s);
    }
    if (data is Uint8List || data is List<int>) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      // 大体积二进制（视频/TS 段）不预览，避免日志膨胀
      if (bytes.length > 64 * 1024) return null;
      try {
        final text = utf8.decode(bytes, allowMalformed: true).trim();
        if (text.isEmpty) return null;
        // 尝试识别为二进制乱码（解码后含大量替换字符）则跳过
        if (text.codeUnits.where((c) => c == 0xFFFD).length > 20) return null;
        return _truncate(text);
      } catch (_) {
        return null;
      }
    }
    try {
      return _truncate(jsonEncode(_mask(data)));
    } catch (_) {
      final s = data.toString();
      return s.isEmpty ? null : _truncate(s);
    }
  }

  /// 递归脱敏: 对 key 命中敏感规则的字段值打码
  static dynamic _mask(dynamic value) {
    if (value is Map) {
      return value.map((k, v) {
        final keyStr = k.toString();
        final sensitive = _sensitiveKey.hasMatch(keyStr);
        return MapEntry(k, sensitive ? '***' : _mask(v));
      });
    }
    if (value is List) {
      return value.map(_mask).toList();
    }
    return value;
  }

  static int? _byteLength(dynamic data) {
    if (data is Uint8List) return data.lengthInBytes;
    if (data is List<int>) return data.length;
    return null;
  }

  static String _truncate(String s, [int max = 2000]) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)} …(已截断，共 ${s.length} 字符)';
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}
