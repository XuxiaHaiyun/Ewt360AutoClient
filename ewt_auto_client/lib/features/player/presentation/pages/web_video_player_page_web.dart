/// Web 平台视频播放页：基于 HTML5 `<video>` 元素 + Flutter 控制栏（浏览器无 mpv）。
/// 阿里云 MP4 直链可直接播放，腾讯云 DRM HLS 受 Origin 限制暂不支持；
/// session+reportConfig 提供时后台并行运行 PlaybackEngine 上报进度。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../../../core/utils/web_file_saver.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';
import '../../domain/entities/report_config.dart';
import '../../domain/entities/video_session.dart';
import '../../domain/services/playback_engine.dart';
import '../../domain/services/video_source_resolver.dart';

/// Web 平台视频播放页 (HTML5 <video> + Flutter 控制栏)
///
/// 浏览器无法运行 mpv (media_kit), 使用平台原生 <video> 元素播放:
/// - 阿里云 VOD MP4 直链可直接播放 (推荐线路, 由 [VideoPlayLauncher] 解析传入);
///   腾讯云 DRM HLS 受浏览器 Origin 头不可覆盖限制, 暂不支持
/// - 支持播放/暂停/进度/倍速/音量/全屏/清晰度切换 (多档 MP4)
/// - [session] + [reportConfig] 提供时, 后台并行运行 [PlaybackEngine] 上报进度
///   (行为与 native 端 [VideoPlayerPage] 一致, 引擎为纯 Dart 在 Web 可用)
///
/// 实现要点: <video> 元素设置 pointer-events:none, 交互全部由 Flutter 层接管
/// (否则平台视图会遮挡 Flutter 控件)。
class WebVideoPlayerPage extends StatefulWidget {
  /// 可播放地址 (MP4 直链; 浏览器原生支持)
  final String videoUrl;
  final String title;
  final String lessonId;

  /// 初始清晰度档位 (多于一档时显示清晰度切换按钮)
  final List<ResolvedVideoQuality> initialQualities;

  /// 视频会话 (提供时启用后台进度上报)
  final VideoSession? session;

  /// 上报配置 (提供时启用后台进度上报)
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
  late final web.HTMLVideoElement _video;
  late final String _viewId;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _eventListeners = <(web.HTMLVideoElement, String, JSFunction)>[];

  // 播放状态 (由 <video> 事件驱动同步)
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _needsUserPlay = false;
  double _positionSec = 0;
  double _durationSec = 0;
  String? _error;

  // 全屏 / 音量 / 倍速
  bool _isFullscreen = false;
  double _volume = 1.0;
  double _speed = 1.0;

  // 清晰度
  late List<ResolvedVideoQuality> _qualities;
  int _qualityIndex = 0;
  double _resumeAfterSwitch = 0;

  // 控制栏显隐
  bool _showControls = true;
  Timer? _hideControlsTimer;

  // 后台上报
  PlaybackEngine? _engine;
  StreamSubscription<PlaybackProgress>? _engineSubscription;
  bool _engineRunning = false;
  final List<_WebLogEntry> _reportLogs = [];

  @override
  void initState() {
    super.initState();
    _qualities = widget.initialQualities;
    _viewId = 'ewt-web-video-${DateTime.now().microsecondsSinceEpoch}';

    _video = web.HTMLVideoElement();
    _video.controls = false;
    _video.playsInline = true;
    _video.src = widget.videoUrl;
    // 交互全部由 Flutter 层接管, 避免 HTML 元素遮挡 Flutter 控件
    _video.style.width = '100%';
    _video.style.height = '100%';
    _video.style.setProperty('object-fit', 'contain');
    _video.style.setProperty('pointer-events', 'none');
    _video.style.setProperty('background', 'black');

    void on(String type, void Function(web.Event) handler) {
      final jsHandler = ((web.Event e) => handler(e)).toJS;
      _video.addEventListener(type, jsHandler);
      _eventListeners.add((_video, type, jsHandler));
    }

    on('timeupdate', (_) {
      if (!mounted) return;
      setState(() => _positionSec = _video.currentTime);
    });
    on('durationchange', (_) {
      if (!mounted) return;
      final d = _video.duration;
      setState(() => _durationSec = d.isFinite ? d : 0);
    });
    on('play', (_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _needsUserPlay = false;
      });
    });
    on('playing', (_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _isBuffering = false;
      });
    });
    on('pause', (_) {
      if (!mounted) return;
      setState(() => _isPlaying = false);
    });
    on('waiting', (_) {
      if (!mounted) return;
      setState(() => _isBuffering = true);
    });
    on('canplay', (_) {
      if (!mounted) return;
      setState(() => _isBuffering = false);
    });
    on('ended', (_) {
      if (!mounted) return;
      setState(() => _isPlaying = false);
      _addLog('播放完成', level: _LogLevel.success);
      _stopReporting();
    });
    on('error', (_) {
      if (!mounted) return;
      final code = _video.error?.code ?? 0;
      final msg = switch (code) {
        1 => '加载中断',
        2 => '网络错误',
        3 => '解码失败',
        4 => '格式不支持或源不可用',
        _ => '未知错误 ($code)',
      };
      setState(() => _error = msg);
      _addLog('播放器错误: $msg', level: _LogLevel.error);
    });

    ui_web.platformViewRegistry.registerViewFactory(
      _viewId,
      (int viewId) => _video,
    );

    // 全屏状态同步 (整页 fullscreen 由浏览器管理)
    web.document.addEventListener(
      'fullscreenchange',
      ((web.Event _) {
        if (!mounted) return;
        setState(() => _isFullscreen = web.document.fullscreenElement != null);
      }).toJS,
    );

    if (widget.session != null) {
      _startReporting();
    }
    _tryPlay();
    _scheduleHideControls();
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _stopReporting();
    for (final (el, type, handler) in _eventListeners) {
      el.removeEventListener(type, handler);
    }
    try {
      _video.pause();
      _video.removeAttribute('src');
    } catch (_) {}
    super.dispose();
  }

  // ─── 播放控制 ───

  Future<void> _tryPlay() async {
    try {
      final p = _video.play().toDart;
      await p;
    } catch (_) {
      // 浏览器自动播放策略拦截 (无用户手势), 显示手动播放按钮
      if (mounted) setState(() => _needsUserPlay = true);
    }
  }

  void _togglePlay() {
    if (_video.paused) {
      _video.play().toDart.catchError((_, _) => null).ignore();
    } else {
      _video.pause();
    }
    _scheduleHideControls();
  }

  void _seekTo(double seconds) {
    final target = seconds.clamp(0.0, _durationSec).toDouble();
    _video.currentTime = target;
    _scheduleHideControls();
    _reportSeek(target.round());
  }

  void _seekBy(int delta) {
    _seekTo(_positionSec + delta);
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _video.playbackRate = s;
    if (_engine != null && _engineRunning) {
      _engine!.setSpeed(s);
      _addLog('[上报] 倍速切换为 ${s}x, 后续上报已同步');
    }
  }

  void _setVolume(double v) {
    setState(() => _volume = v);
    _video.volume = v.clamp(0.0, 1.0);
  }

  /// 切换清晰度: 换 src 并从当前进度继续
  void _switchQuality(int idx) {
    if (idx < 0 || idx >= _qualities.length || idx == _qualityIndex) return;
    final resume = _positionSec;
    setState(() => _qualityIndex = idx);
    _addLog('切换清晰度 → ${_qualities[idx].label}, 从 ${_formatDuration(resume)} 继续');
    _resumeAfterSwitch = resume;
    _video.src = _qualities[idx].url;
    _video.load();
    // loadedmetadata 后恢复进度与播放状态
    onOnce('loadedmetadata', (_) {
      _video.currentTime = _resumeAfterSwitch;
      _video.play().toDart.catchError((_, _) => null).ignore();
    });
  }

  void onOnce(String type, void Function(web.Event) handler) {
    late final JSFunction jsHandler;
    jsHandler = ((web.Event e) {
      _video.removeEventListener(type, jsHandler);
      handler(e);
    }).toJS;
    _video.addEventListener(type, jsHandler);
  }

  // ─── 全屏 (整页, Flutter 控制栏保持可见) ───

  void _toggleFullscreen() {
    if (_isFullscreen) {
      web.document.exitFullscreen().toDart.ignore();
    } else {
      web.document.documentElement?.requestFullscreen().toDart.ignore();
    }
  }

  // ─── 截图 (经浏览器下载) ───

  Future<void> _takeScreenshot() async {
    if (_durationSec <= 0) {
      _showSnackBar('请先加载视频再截图');
      return;
    }
    try {
      // 以视频当前帧为源绘制到离屏 canvas 导出 PNG
      final cv = web.HTMLCanvasElement();
      cv.width = _video.videoWidth;
      cv.height = _video.videoHeight;
      final ctx = cv.getContext('2d') as web.CanvasRenderingContext2D;
      ctx.drawImage(_video, 0, 0);
      final blob = await _canvasToBlob(cv);
      final buffer = await blob.arrayBuffer().toDart;
      final bytes = buffer.toDart.asUint8List();
      final filename =
          'ewt_screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      final path = await WebFileSaver.saveBytes(filename, bytes);
      _showSnackBar('截图已保存: $path');
      _addLog('截图: $path', level: _LogLevel.success);
    } catch (e) {
      _showSnackBar('截图失败: $e');
      _addLog('截图异常: $e', level: _LogLevel.error);
    }
  }

  /// HTMLCanvasElement.toBlob 回调式 API → Future
  Future<web.Blob> _canvasToBlob(web.HTMLCanvasElement cv) {
    final c = Completer<web.Blob>();
    cv.toBlob(((web.Blob? b) {
      if (b != null) {
        c.complete(b);
      } else {
        c.completeError(StateError('canvas.toBlob 返回空 blob'));
      }
    }).toJS);
    return c.future;
  }

  // ─── 后台进度上报 (与 native 端 VideoPlayerPage 对齐) ───

  void _startReporting() {
    if (widget.session == null) {
      _addLog('播放已开始 (未启用服务端上报)');
      return;
    }
    if (_engineRunning) return;

    final client = getIt<DioClient>();
    final endpointConfig = getIt<EndpointConfig>();
    final playerRemote = PlayerRemoteDataSource(client);
    final telemetryRemote = TelemetryRemoteDataSource(client);

    _engine = PlaybackEngine(
      playerRemote: playerRemote,
      telemetryRemote: telemetryRemote,
      endpointConfig: endpointConfig,
    );

    _engineSubscription = _engine!.progressStream.listen((progress) {
      if (!mounted) return;
      final level = switch (progress.state) {
        PlaybackState.completed => _LogLevel.success,
        PlaybackState.failed => _LogLevel.error,
        PlaybackState.cancelled => _LogLevel.warning,
        PlaybackState.focusChecking => _LogLevel.warning,
        _ => _LogLevel.info,
      };
      final msg = progress.message ?? progress.state.name;
      _addLog('[上报] $msg', level: level);
      if (progress.state == PlaybackState.completed) {
        _engineRunning = false;
      } else if (progress.state == PlaybackState.failed ||
          progress.state == PlaybackState.cancelled) {
        _engineRunning = false;
      }
    });

    _engineRunning = true;
    _addLog('[上报] 后台进度上报已启动', level: _LogLevel.success);

    final config = widget.reportConfig ?? const ReportConfig();
    _engine!.simulatePlayback(
      widget.session!,
      fastMode: config.fastBrush,
      heartbeatInterval: config.heartbeatInterval,
      speed: config.speed,
      fastBrushMaxRounds: config.fastBrushMaxRounds,
      completeRatio: config.completionThreshold,
      realProgressQuery: config.realProgressQuery,
      progressPollInterval: config.progressPollInterval,
      resumeFromServer: config.resumeFromServer,
      useBackup: config.useBackup,
      reportBackend: config.reportBackend,
      rebrush: config.rebrush,
      rebrushRounds: config.rebrushRounds,
      rebrushExtraMinutes: config.rebrushExtraMinutes,
      compensate: config.compensate,
      fastBrush2: config.fastBrush2,
      fastBrushSessions: config.fastBrushSessions,
    ).catchError((e) {
      if (mounted) _addLog('[上报] 引擎异常: $e', level: _LogLevel.error);
      _engineRunning = false;
      return null;
    });
  }

  void _stopReporting() {
    _engineSubscription?.cancel();
    _engineSubscription = null;
    _engine?.cancel();
    _engine?.dispose();
    _engine = null;
    _engineRunning = false;
  }

  void _reportSeek(int positionSeconds) {
    if (_engine == null || !_engineRunning) return;
    _engine!.reportSeek(positionSeconds).then((_) {
      _addLog('[上报] seek → ${_formatDuration(positionSeconds.toDouble())}');
    }).catchError((e) {
      _addLog('[上报] seek 上报失败: $e', level: _LogLevel.warning);
    });
  }

  // ─── 控制栏显隐 / 杂项 ───

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() => _showControls = true);
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying) setState(() => _showControls = false);
    });
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _addLog(String message, {_LogLevel level = _LogLevel.info}) {
    if (!mounted) return;
    setState(() {
      _reportLogs.add(_WebLogEntry(
        message: message,
        level: level,
        time: DateTime.now(),
      ));
      if (_reportLogs.length > 200) _reportLogs.removeAt(0);
    });
  }

  String _formatDuration(double seconds) {
    final d = Duration(seconds: seconds.round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      appBar: _isFullscreen
          ? null
          : AppBar(
              backgroundColor: theme.colorScheme.surface,
              foregroundColor: theme.colorScheme.onSurface,
              title: Text(
                widget.title,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (RiskControlGate.isFeatureEnabled('player.screenshot'))
                  IconButton(
                    icon: const Icon(Icons.camera_alt_outlined),
                    tooltip: '截图',
                    onPressed: _takeScreenshot,
                  ),
                if (RiskControlGate.isFeatureEnabled('player.report_log'))
                  IconButton(
                    icon: Badge(
                      isLabelVisible: _reportLogs.isNotEmpty,
                      label: Text('${_reportLogs.length}'),
                      child: const Icon(Icons.receipt_long_outlined),
                    ),
                    tooltip: '上报日志',
                    onPressed: () =>
                        _scaffoldKey.currentState?.openEndDrawer(),
                  ),
              ],
            ),
      endDrawer: _buildLogDrawer(theme),
      body: GestureDetector(
        onTap: _scheduleHideControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // HTML5 视频平台视图 (pointer-events:none, 交互由 Flutter 接管)
            HtmlElementView(viewType: _viewId),

            if (_error != null)
              Center(
                child: Container(
                  margin: const EdgeInsets.all(32),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline,
                          color: theme.colorScheme.error, size: 40),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: TextStyle(
                            color: theme.colorScheme.onErrorContainer),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),

            // 自动播放被浏览器策略拦截: 手动播放按钮
            if (_needsUserPlay && _error == null)
              Center(
                child: IconButton(
                  iconSize: 72,
                  icon: const Icon(Icons.play_circle_filled,
                      color: Colors.white),
                  tooltip: '播放',
                  onPressed: () {
                    setState(() => _needsUserPlay = false);
                    _tryPlay();
                  },
                ),
              ),

            if (_isBuffering && !_needsUserPlay)
              const Center(child: CircularProgressIndicator()),

            // 底部控制栏
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: _buildControlBar(theme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                activeTrackColor: theme.colorScheme.primary,
                inactiveTrackColor: Colors.white24,
                thumbColor: theme.colorScheme.primary,
                overlayColor: theme.colorScheme.primary.withValues(alpha: 0.12),
              ),
              child: Slider(
                value: _durationSec > 0
                    ? (_positionSec / _durationSec).clamp(0.0, 1.0)
                    : 0.0,
                onChanged: _durationSec > 0
                    ? (v) => _seekTo(v * _durationSec)
                    : null,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                SizedBox(
                  width: 100,
                  child: Text(
                    '${_formatDuration(_positionSec)} / ${_formatDuration(_durationSec)}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  icon: const Icon(Icons.replay_10, color: Colors.white),
                  tooltip: '快退10秒',
                  onPressed: () => _seekBy(-10),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  iconSize: 38,
                  icon: Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: Colors.white,
                  ),
                  onPressed: _togglePlay,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  icon: const Icon(Icons.forward_10, color: Colors.white),
                  tooltip: '快进10秒',
                  onPressed: () => _seekBy(10),
                ),
                const Spacer(),
                if (_qualities.length > 1)
                  _WebQualityButton(
                    qualities: _qualities,
                    current: _qualityIndex,
                    onSelected: _switchQuality,
                  ),
                _WebSpeedButton(speed: _speed, onSelected: _setSpeed),
                _WebVolumeButton(volume: _volume, onChanged: _setVolume),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  icon: Icon(
                    _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    color: Colors.white,
                  ),
                  tooltip: _isFullscreen ? '退出全屏' : '全屏',
                  onPressed: _toggleFullscreen,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogDrawer(ThemeData theme) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.receipt_long,
                      size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('上报日志', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  if (_engineRunning)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        '上报中',
                        style: TextStyle(color: Colors.green, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _reportLogs.isEmpty
                  ? const Center(
                      child: Text('暂无日志',
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _reportLogs.length,
                      itemBuilder: (context, index) {
                        final log = _reportLogs[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '[${_formatTime(log.time)}] ${log.message}',
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: switch (log.level) {
                                _LogLevel.info =>
                                  theme.colorScheme.onSurfaceVariant,
                                _LogLevel.success => Colors.green,
                                _LogLevel.warning => Colors.orange,
                                _LogLevel.error => theme.colorScheme.error,
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _reportLogs.isEmpty
                        ? null
                        : () {
                            final text = _reportLogs
                                .map((l) =>
                                    '[${_formatTime(l.time)}] ${l.message}')
                                .join('\n');
                            Clipboard.setData(ClipboardData(text: text));
                            _showSnackBar('日志已复制');
                          },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => setState(() => _reportLogs.clear()),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}

// ─── 清晰度按钮 ───

class _WebQualityButton extends StatelessWidget {
  final List<ResolvedVideoQuality> qualities;
  final int current;
  final ValueChanged<int> onSelected;

  const _WebQualityButton({
    required this.qualities,
    required this.current,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final label = current >= 0 && current < qualities.length
        ? qualities[current].label
        : '清晰度';
    return PopupMenuButton<int>(
      tooltip: '清晰度: $label',
      offset: const Offset(0, -220),
      initialValue: current,
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        for (var i = 0; i < qualities.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                if (i == current)
                  Icon(Icons.check,
                      size: 16, color: Theme.of(context).colorScheme.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(qualities[i].label),
              ],
            ),
          ),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          '清晰度',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ─── 倍速按钮 ───

class _WebSpeedButton extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onSelected;

  const _WebSpeedButton({required this.speed, required this.onSelected});

  static const _options = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: '倍速',
      offset: const Offset(0, -200),
      initialValue: speed,
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        for (final s in _options)
          PopupMenuItem<double>(
            value: s,
            child: Row(
              children: [
                if (s == speed)
                  Icon(Icons.check,
                      size: 16, color: Theme.of(context).colorScheme.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text('${s}x'),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          '${speed}x',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ─── 音量按钮 ───

class _WebVolumeButton extends StatelessWidget {
  final double volume;
  final ValueChanged<double> onChanged;

  const _WebVolumeButton({required this.volume, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: '音量',
      offset: const Offset(0, -160),
      onSelected: onChanged,
      itemBuilder: (ctx) => [
        PopupMenuItem<double>(
          enabled: false,
          child: SizedBox(
            width: 140,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      volume == 0
                          ? Icons.volume_off
                          : volume < 0.5
                              ? Icons.volume_down
                              : Icons.volume_up,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text('${(volume * 100).round()}%'),
                  ],
                ),
                Slider(
                  value: volume,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Icon(
          volume == 0
              ? Icons.volume_off
              : volume < 0.5
                  ? Icons.volume_down
                  : Icons.volume_up,
          color: Colors.white,
          size: 22,
        ),
      ),
    );
  }
}

// ─── 辅助类 ───

class _WebLogEntry {
  final String message;
  final _LogLevel level;
  final DateTime time;

  const _WebLogEntry({
    required this.message,
    required this.level,
    required this.time,
  });
}

enum _LogLevel { info, success, warning, error }
