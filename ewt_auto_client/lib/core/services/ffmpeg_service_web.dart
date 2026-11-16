// web/ffmpeg_bridge.js 注入到 window 的桥接对象
//
// 通过 ffmpeg.wasm 在浏览器中执行 TS→MP4 remux, 与 native 端能力对齐。
// 该实现替换原 stub, 让 Web 平台也支持视频下载。

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'ffmpeg_load_progress.dart';

/// window.EwtFFmpeg 桥接对象的 Dart 视图
///
/// 由 web/ffmpeg_bridge.js 注入到 window, 提供:
///   - isLoaded: bool       (ffmpeg core 是否已加载)
///   - load(): `Promise<void>`  (加载 core, 仅首次需要)
///   - setCdnBase(String): void (切换 CDN 根地址, 需在 load 前调用)
///   - onLoadProgress(JSFunction): void (订阅加载进度, 单订阅)
///   - abortLoad(): void    (中止进行中的 core 下载)
///   - remuxToMp4(Uint8Array): `Promise<Uint8Array>`  (TS→MP4 remux)
@JS()
extension type _EwtFFmpeg._(JSObject _) implements JSObject {
  external bool get isLoaded;
  external JSPromise<JSAny?> load();
  external void setCdnBase(JSString base);
  external void onLoadProgress(JSFunction cb);
  external void abortLoad();
  external JSPromise<JSUint8Array> remuxToMp4(JSUint8Array tsBytes);
}

/// 加载进度回调载荷 (bridge 传来的 JSObject 视图)
@JS()
extension type _LoadProgressPayload._(JSObject _) implements JSObject {
  external String get phase;
  external int get receivedBytes;
  external int get totalBytes;
  external double get ratio;
}

/// Web 平台的 FFmpegKit 桥接实现 (基于 ffmpeg.wasm)
///
/// 调用 window.EwtFFmpeg (web/ffmpeg_bridge.js 注入), 通过 dart:js_interop 通信。
/// 实际能力:
///   - load()              懒加载 ffmpeg core wasm (首次调用时触发, 带进度/可取消)
///   - remuxToMp4(bytes)   TS→MP4 流拷贝 (内存版, 输入输出均为 Uint8List)
///   - remuxToMp4(path)    不可用 (Web 无文件系统), 调用方应改用 bytes 版本
class FfmpegKitBridge {
  FfmpegKitBridge._();
  static final FfmpegKitBridge instance = FfmpegKitBridge._();

  bool _inited = false;

  /// 加载 ffmpeg.wasm core (仅首次需要, 内部带去重)
  ///
  /// wasm core (~25MB) 从 CDN 拉取, 首次加载需要数秒;
  /// [onProgress] 订阅下载进度, [cdnBase] 切换 CDN 根地址 (须在加载前生效)。
  /// 失败抛异常, 由上层捕获转为错误描述; 失败后可换 CDN 重试。
  Future<void> init({
    void Function(FfmpegLoadProgress progress)? onProgress,
    String? cdnBase,
  }) async {
    if (_inited) return;
    final bridge = _resolveBridge();
    if (cdnBase != null && cdnBase.isNotEmpty) {
      bridge.setCdnBase(cdnBase.toJS);
    }
    if (onProgress != null) {
      bridge.onLoadProgress(((JSObject p) {
        final info = _LoadProgressPayload._(p);
        onProgress(FfmpegLoadProgress(
          phase: info.phase,
          receivedBytes: info.receivedBytes,
          totalBytes: info.totalBytes,
          ratio: info.ratio.isNaN ? 0 : info.ratio,
        ));
      }).toJS);
    }
    try {
      await bridge.load().toDart;
      _inited = true;
    } catch (e) {
      // 失败后允许重试 (bridge 内部已重建实例)
      rethrow;
    }
  }

  /// 中止进行中的 core 下载 (load future 将以"已取消"失败)
  void abortLoad() {
    try {
      _resolveBridge().abortLoad();
    } catch (_) {}
  }

  /// TS → MP4 remux: `ffmpeg -y -i input.ts -c copy output.mp4` (内存版)
  ///
  /// Web 端无法用文件路径, 必须传入 TS 字节序列, 返回 MP4 字节序列。
  /// 返回错误描述字符串 (与 native 路径版接口语义对齐)。
  Future<String?> remuxToMp4({
    required String inputPath,
    required String outputPath,
  }) async {
    // Web 平台无文件系统, 路径版接口不可用。
    // 调用方 (DownloadService) 应在 web 端改走 remuxToMp4Bytes 路径。
    return 'Web 平台不支持路径版 ffmpeg, 请改用 remuxToMp4Bytes';
  }

  /// TS → MP4 remux (内存版, Web 专用)
  ///
  /// 输入: TS 字节序列
  /// 输出: MP4 字节序列 (成功) 或 null (失败)
  /// 错误描述通过返回值的 error 字段返回 (与 native 版的 String? 返回值语义对齐)。
  Future<({Uint8List? bytes, String? error})> remuxToMp4Bytes(
    Uint8List tsBytes,
  ) async {
    try {
      await init();
      final bridge = _resolveBridge();
      // Uint8List → JSUint8Array (零拷贝视图)
      final jsInput = tsBytes.toJS;
      final jsOutput = await bridge.remuxToMp4(jsInput).toDart;
      // JSUint8Array → Uint8List (零拷贝)
      final mp4Bytes = jsOutput.toDart;
      return (bytes: mp4Bytes, error: null);
    } catch (e) {
      return (bytes: null, error: 'ffmpeg.wasm remux 失败: $e');
    }
  }

  /// 获取 window.EwtFFmpeg 引用
  ///
  /// 通过 dart:js_interop_unsafe 的 [] 操作符访问 'EwtFFmpeg' 属性。
  /// 未注入则抛 StateError (说明 web/index.html 未正确加载 ffmpeg_bridge.js)。
  _EwtFFmpeg _resolveBridge() {
    // globalContext 即 JS 全局对象 (window), 用 unsafe [] 访问自定义属性
    final obj = globalContext['EwtFFmpeg'];
    if (obj == null) {
      throw StateError(
          'window.EwtFFmpeg 未注入, 请检查 web/index.html 是否加载 ffmpeg_bridge.js');
    }
    // 用 isA<JSObject>() 做 JS interop 安全类型检查 (避免 dart is! 的非跨平台行为)
    if (!obj.isA<JSObject>()) {
      throw StateError(
          'window.EwtFFmpeg 不是 JSObject (类型异常)');
    }
    return _EwtFFmpeg._(obj as JSObject);
  }
}
