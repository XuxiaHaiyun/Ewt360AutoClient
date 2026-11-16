/// 跨平台 FFmpeg 服务: 封装 TS→MP4 remux (`-c copy` 不重编码),
/// native 用 ffmpeg_kit_flutter_new_min, Web 用 ffmpeg.wasm (条件导入切换)。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'ffmpeg_load_progress.dart';
import 'ffmpeg_service_platform.dart'
    if (dart.library.js_interop) 'ffmpeg_service_web.dart'
    as impl;

/// 跨平台 FFmpeg 服务
///
/// 封装底层 ffmpeg 实现, 提供 TS→MP4 remux 能力。
/// - Android / Windows / iOS / macOS / Linux: 使用 ffmpeg_kit_flutter_new_min
/// - Web: 使用 ffmpeg.wasm (通过 web/ffmpeg_bridge.js 桥接, 由 CDN 加载 core wasm)
///
/// 使用 `-c copy` 流拷贝, 不重编码, 对 H.264/AAC 内容无需外部编解码库。
///
/// 提供两种调用方式:
/// - [remuxToMp4]: 文件路径版 (native 专用, web 调用返回不支持)
/// - [remuxToMp4Bytes]: 内存版 (跨平台, 输入输出均为 [Uint8List])
class FfmpegService {
  FfmpegService._();

  /// 单例
  static final FfmpegService instance = FfmpegService._();

  bool _initialized = false;

  /// 是否支持 ffmpeg
  ///
  /// Web 与 native 平台均支持, 返回 true。
  /// (web 端通过 ffmpeg.wasm 实现, native 端通过 ffmpeg_kit_flutter_new_min)
  bool get isSupported => true;

  /// ffmpeg 是否已完成初始化 (web: core wasm 已加载)
  bool get isInitialized => _initialized;

  /// 初始化 ffmpeg
  ///
  /// - Native: 调用 FFmpegKitConfig.init()
  /// - Web: 加载 ffmpeg.wasm core (首次会从 CDN 拉取 ~25MB wasm, 需数秒)
  ///
  /// [onProgress] 订阅 core 下载进度 (仅 web 有效);
  /// [cdnBase] 切换 CDN 根地址 (仅 web 有效, 见 [kFfmpegCdnPresets])。
  Future<void> ensureInitialized({
    void Function(FfmpegLoadProgress progress)? onProgress,
    String? cdnBase,
  }) async {
    if (_initialized) return;
    await impl.FfmpegKitBridge.instance.init(
      onProgress: onProgress,
      cdnBase: cdnBase,
    );
    _initialized = true;
  }

  /// 中止进行中的 wasm core 下载 (仅 web 有效)
  ///
  /// 进行中的 [ensureInitialized] future 将以"已取消"失败。
  void abortLoad() {
    try {
      impl.FfmpegKitBridge.instance.abortLoad();
    } catch (_) {}
  }

  /// TS → MP4 remux (文件路径版, native 专用)
  ///
  /// 等价命令: `ffmpeg -y -i input.ts -c copy output.mp4`
  ///
  /// [inputPath] 必须存在且可读; [outputPath] 的父目录必须存在。
  /// 返回 null 表示成功, 非 null 为错误描述。
  ///
  /// Web 平台无文件系统, 调用此方法会返回错误描述。
  /// Web 调用方应改用 [remuxToMp4Bytes]。
  Future<String?> remuxToMp4({
    required String inputPath,
    required String outputPath,
  }) async {
    await ensureInitialized();
    return impl.FfmpegKitBridge.instance.remuxToMp4(
      inputPath: inputPath,
      outputPath: outputPath,
    );
  }

  /// TS → MP4 remux (内存版, 跨平台)
  ///
  /// 输入 [tsBytes] 为 TS 字节序列, 返回 MP4 字节序列。
  /// - Native: 写临时文件 → 调路径版 → 读回 → 删除临时文件
  /// - Web: 调用 ffmpeg.wasm 虚拟 FS (writeFile/exec/readFile)
  ///
  /// 返回 (bytes, error):
  /// - 成功: bytes 非 null / error 为 null
  /// - 失败: bytes 为 null / error 为错误描述
  Future<({Uint8List? bytes, String? error})> remuxToMp4Bytes(
    Uint8List tsBytes,
  ) async {
    await ensureInitialized();
    return impl.FfmpegKitBridge.instance.remuxToMp4Bytes(tsBytes);
  }
}
