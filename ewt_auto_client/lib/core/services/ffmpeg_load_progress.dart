/// ffmpeg.wasm 加载进度与 CDN 预设 (平台中立, 供 facade/impl/dialog 共用)
library;

/// ffmpeg.wasm 核心组件加载进度
///
/// [phase]:
/// - `script`: 加载 ffmpeg core JS 胶水脚本 (~0.1MB)
/// - `wasm`  : 下载 ffmpeg core wasm 主体 (~25MB)
/// [ratio] 为总体进度 0~1 (script 占 5%, wasm 占 95%);
/// [totalBytes] 为 0 表示 CDN 未返回长度 (进度不可知, 仅显示已下载量)。
class FfmpegLoadProgress {
  final String phase;
  final int receivedBytes;
  final int totalBytes;
  final double ratio;

  const FfmpegLoadProgress({
    required this.phase,
    required this.receivedBytes,
    required this.totalBytes,
    required this.ratio,
  });
}

/// ffmpeg.wasm core 下载 CDN 预设
///
/// 值为包源根地址, 拼接 `/@ffmpeg/core@0.12.6/dist/umd/ffmpeg-core{.js,.wasm}`。
/// 默认使用 npmmirror (国内直连快); unpkg 在国内经常缓慢/超时。
const List<(String, String)> kFfmpegCdnPresets = [
  ('npmmirror (国内推荐)', 'https://registry.npmmirror.com'),
  ('jsdelivr', 'https://cdn.jsdelivr.net/npm'),
  ('unpkg', 'https://unpkg.com'),
];

/// CDN 选择持久化键 (SharedPreferences)
const String kFfmpegCdnPrefKey = 'ewt_ffmpeg_cdn';

/// 默认 CDN 根地址
const String kFfmpegCdnDefault = 'https://registry.npmmirror.com';
