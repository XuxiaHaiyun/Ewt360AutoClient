/// WebVideoPlayerPage 的非 Web 平台占位实现：仅保证编译可达，
/// native 端由 VideoPlayLauncher 按 kIsWeb 分发，永远不会路由到本页面。
library;

import 'package:flutter/material.dart';

import '../../domain/entities/report_config.dart';
import '../../domain/entities/video_session.dart';
import '../../domain/services/video_source_resolver.dart';

/// VM (Windows/Android 运行/测试) 平台的占位实现
///
/// Web 平台实现见 web_video_player_page_web.dart (经
/// web_video_player_page.dart 条件导出分发)。native 端永远不会
/// 路由到本页面 (VideoPlayLauncher 按 kIsWeb 分发), 仅保证编译可达,
/// 故构造参数签名与 Web 实现保持一致。
class WebVideoPlayerPage extends StatefulWidget {
  final String videoUrl;
  final String title;
  final String lessonId;
  final List<ResolvedVideoQuality> initialQualities;
  final VideoSession? session;
  final ReportConfig? reportConfig;

  const WebVideoPlayerPage({
    super.key,
    required this.videoUrl,
    this.title = '视频播放',
    this.lessonId = '',
    this.initialQualities = const [],
    this.session,
    this.reportConfig,
  });

  @override
  State<WebVideoPlayerPage> createState() => _WebVideoPlayerPageState();
}

class _WebVideoPlayerPageState extends State<WebVideoPlayerPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_outlined, size: 48),
            const SizedBox(height: 12),
            const Text('Web 播放器仅在 Web 平台可用'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
