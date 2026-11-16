/// FFmpegKit 原生平台桥接 (Android/Windows/iOS/macOS/Linux):
/// 提供 init (失败重试 3 次)、路径版与内存版 TS→MP4 remux; 接口与 web 端对齐。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path_provider/path_provider.dart';

import 'ffmpeg_load_progress.dart';

/// 原生平台 (Android/Windows/iOS/macOS/Linux) 的 FFmpegKit 桥接实现
class FfmpegKitBridge {
  FfmpegKitBridge._();
  static final FfmpegKitBridge instance = FfmpegKitBridge._();

  bool _inited = false;

  /// [onProgress]/[cdnBase] 仅 Web 有意义, native 忽略 (接口与 web 对齐)
  Future<void> init({
    void Function(FfmpegLoadProgress progress)? onProgress,
    String? cdnBase,
  }) async {
    if (_inited) return;
    // 重试 3 次 (Windows 上 libffmpegkit.dll 加载可能瞬时失败)
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await FFmpegKitConfig.init();
        _inited = true;
        return;
      } catch (e) {
        if (attempt == 2) rethrow;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// 中止进行中的 wasm core 下载 (native 无此概念, no-op, 接口与 web 对齐)
  void abortLoad() {}

  /// TS → MP4 remux: `ffmpeg -y -i input.ts -c copy output.mp4`
  ///
  /// 返回 null 表示成功, 非 null 为错误描述。
  Future<String?> remuxToMp4({
    required String inputPath,
    required String outputPath,
  }) async {
    await init();
    // 用 executeWithArguments 避免路径含空格/特殊字符被 parseArguments 误拆
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      inputPath,
      '-c',
      'copy',
      outputPath,
    ]);
    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) {
      return null; // 成功
    }
    // 失败: 提取最后的日志行作为错误信息
    final logs = await session.getLogsAsString();
    final lines = logs.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final tail = lines.length > 8 ? lines.sublist(lines.length - 8).join('\n') : logs;
    return 'ffmpeg 退出码 ${returnCode?.getValue()}: $tail';
  }

  /// TS → MP4 remux (内存版)
  ///
  /// 与 web 端 [remuxToMp4Bytes] 对齐的内存版接口。
  /// 实现: 写临时 TS 文件 → 调 [remuxToMp4] 路径版 → 读回 MP4 字节 → 删除临时文件。
  ///
  /// 返回 (bytes, error): 成功 bytes 非 null / error 为 null; 失败反之。
  Future<({Uint8List? bytes, String? error})> remuxToMp4Bytes(
    Uint8List tsBytes,
  ) async {
    // 临时文件目录 (使用应用缓存目录, 避免污染用户下载目录)
    Directory? tempBase;
    try {
      tempBase = await getTemporaryDirectory();
    } catch (_) {
      // 退回系统 temp
      tempBase = Directory.systemTemp;
    }
    final tempDir = Directory('${tempBase.path}/ewt_ffmpeg');
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    // 唯一临时文件名 (避免并发冲突)
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tsPath = '${tempDir.path}/$stamp.ts';
    final mp4Path = '${tempDir.path}/$stamp.mp4';

    try {
      await File(tsPath).writeAsBytes(tsBytes);
      final err = await remuxToMp4(inputPath: tsPath, outputPath: mp4Path);
      if (err != null) {
        return (bytes: null, error: err);
      }
      final mp4File = File(mp4Path);
      if (!mp4File.existsSync() || mp4File.lengthSync() == 0) {
        return (bytes: null, error: 'ffmpeg 未产出文件');
      }
      final mp4Bytes = await mp4File.readAsBytes();
      return (bytes: mp4Bytes, error: null);
    } catch (e) {
      return (bytes: null, error: 'ffmpeg 内存版 remux 异常: $e');
    } finally {
      // 清理临时文件 (失败不阻断)
      try { File(tsPath).deleteSync(); } catch (_) {}
      try { File(mp4Path).deleteSync(); } catch (_) {}
    }
  }
}
