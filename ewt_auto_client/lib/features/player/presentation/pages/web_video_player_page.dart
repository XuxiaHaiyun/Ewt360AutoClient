/// Web 平台视频播放器 — 平台分发门面
///
/// - Web (dart2js / dart2wasm): [web_video_player_page_web.dart]
///   (HTML5 <video> + Flutter 控制栏 + 后台进度上报)
/// - VM / native: [web_video_player_page_stub.dart]
///   (占位实现, native 端由 VideoPlayLauncher 路由到 media_kit 播放器,
///   本页面仅保证 import 图在所有平台可编译)
///
/// 使用方 (VideoPlayLauncher) 无需感知平台差异。
library;

export 'web_video_player_page_stub.dart'
    if (dart.library.js_interop) 'web_video_player_page_web.dart';
