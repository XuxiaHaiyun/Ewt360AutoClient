/// 视频播放页（media_kit/mpv 内核）：播放/暂停、倍速、清晰度与线路切换、
/// 截图、画中画等，并在提供 session+reportConfig 时后台并行运行 PlaybackEngine 上报进度。
/// 用户切倍速/seek 会实时同步到引擎，对齐 Web 播放器事件上报。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/network/api_helper.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../../../core/utils/web_file_saver.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';
import '../../domain/entities/report_config.dart';
import '../../domain/entities/video_session.dart';
import '../../domain/services/playback_engine.dart';
import '../../domain/services/aliyun_hls_proxy.dart';
import '../../domain/services/video_source_resolver.dart';

/// 视频播放页
///
/// 功能: 播放/暂停、快进快退10s、粘贴播放、截图、画中画、字幕开关、
///       倍速、音量、全屏、后台进度上报 + 日志 Drawer 侧边栏
///
/// 对应 Python: gui/dialogs/player.py VideoPlayerDialog
///
/// 当提供 [session] 和 [reportConfig] 时, 在真实播放视频的同时后台运行
/// PlaybackEngine 上报进度 (对齐 Python VideoPlayerDialog 后台运行 PlayerBehaviorTask).
/// 两者并行执行, 互不阻塞: 用户观看视频, 引擎模拟 Web 播放器行为链上报网络包.
/// 用户切换倍速/seek 时, 实时同步到引擎 (对齐 Web 播放器事件上报).
///
/// 实时点播: 调用方可直接传入由 [VideoSourceResolver] 解析出的真实地址
/// ([videoUrl] + 可选 [drmToken])。若仅传 [videoUrl] 而无 [drmToken],
/// 则按普通直链播放。
class VideoPlayerPage extends StatefulWidget {
  /// 可播放的 URL (m3u8 / MP4 直链 / 任意 mpv 支持的协议)
  ///
  /// 对于腾讯云 DRM HLS, 此 URL 应为 [VideoSourceResolver] 解析出的
  /// drmOutput[0].url, 同时提供 [drmToken]。
  final String? videoUrl;
  final String title;
  final String lessonId;

  /// 腾讯云 DRM token (仅 m3u8 + DRM 时需要, MP4 直链留空)
  ///
  /// 传入后, 播放器会把 token 追加到 m3u8 内嵌的 key URI 后面, 用于
  /// 通过 CDN 的 DRM key 鉴权 (避免 403)。
  final String drmToken;

  /// 原始视频源信息 ([PlayerRemoteDataSource.getExternalVideoInfo] 返回的 videoList)
  ///
  /// 提供后可启用"线路切换" (腾讯云 / 阿里云): 播放时重新解析对应线路并切换播放。
  /// 不传则无线路切换入口。
  final Map<String, dynamic>? videoInfo;

  /// 初始清晰度档位 ([VideoSourceResolver] 解析结果, 首项 = 默认选中)
  ///
  /// 多于一项时播放器显示"清晰度"切换按钮, 切换时从当前进度继续播放。
  final List<ResolvedVideoQuality> initialQualities;

  /// 视频会话 (提供时启用后台进度上报)
  final VideoSession? session;

  /// 上报配置 (提供时启用后台进度上报)
  final ReportConfig? reportConfig;

  const VideoPlayerPage({
    super.key,
    this.videoUrl,
    this.title = '视频播放',
    this.lessonId = '',
    this.drmToken = '',
    this.videoInfo,
    this.initialQualities = const [],
    this.session,
    this.reportConfig,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final Player _player;
  late final VideoController _videoController;

  // 播放状态
  bool _isPlaying = false;
  bool _isBuffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  // 全屏
  bool _isFullscreen = false;

  // 音量 (0~100)
  double _volume = 100;

  // 倍速
  double _speed = 1.0;

  // 线路 (默认自动, 提供 videoInfo 时可用)
  VideoLine _line = VideoLine.auto;
  VideoSourceResolver? _resolver;
  bool _lineSwitching = false;

  // 清晰度 (解析结果多于一项时可用; 线路切换后随新解析结果更新)
  List<ResolvedVideoQuality> _qualities = const [];
  int _qualityIndex = 0;

  /// 本页内部启动的阿里云私有加密解密代理 (线路切换时创建)
  ///
  /// launcher 启动的那个由 launcher 在页面关闭时回收; 这里只管页面自己起的。
  AliyunHlsProxy? _proxy;

  /// 当前生效的 DRM token (清晰度切换时需携带同一 token 重新打开 m3u8)
  String _activeDrmToken = '';

  /// 阿里云线路音频解码错误的自动回退是否已执行 (防止无限循环重试)
  ///
  /// 用户手动切换线路或成功切到非阿里云线路时重置, 以便再次触发自动回退。
  bool _aliyunAudioFallbackDone = false;

  /// 当前阿里云线路内的备用转码档 URL (首选解码失败时在同线路内换档重试)
  List<String> _aliyunFallbacks = const [];

  /// 正在使用的备用转码档索引 (避免重复尝试同一 URL)
  int _aliyunFallbackIndex = 0;

  // 画中画 (Android 8.0+)
  static const _pipChannel = MethodChannel('ewt_auto_client/pip');
  bool _pipAvailable = false;

  /// 是否移动端 (自动横屏 + 布局简化)
  ///
  /// kIsWeb 短路: dart:io Platform 在 Web 端访问会抛 UnsupportedError
  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  // 进度上报日志
  final List<_LogEntry> _reportLogs = [];

  // 后台 PlaybackEngine (可选, 提供时在真实播放的同时上报进度)
  PlaybackEngine? _engine;
  StreamSubscription<PlaybackProgress>? _engineSubscription;
  bool _engineRunning = false;

  // 控制栏显示
  bool _showControls = true;
  Timer? _hideControlsTimer;

  // 订阅
  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);

    // 提供原始视频源信息时, 初始化线路解析器以支持线路切换
    if (widget.videoInfo != null && widget.videoInfo!.isNotEmpty) {
      _resolver = VideoSourceResolver(client: getIt<DioClient>());
    }

    // 初始清晰度档位 (来自启动器解析结果, 首项 = 默认)
    _qualities = widget.initialQualities;
    _activeDrmToken = widget.drmToken;

    // 移动端: 进入页面自动横屏 + 默认全屏
    if (_isMobile) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      _isFullscreen = true;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    // 检测画中画可用性 (仅 Android)
    _checkPipAvailability();

    _subscriptions.addAll([
      _player.stream.playing.listen((playing) {
        if (mounted) setState(() => _isPlaying = playing);
      }),
      _player.stream.position.listen((pos) {
        if (mounted) setState(() => _position = pos);
      }),
      _player.stream.duration.listen((dur) {
        if (mounted) setState(() => _duration = dur);
      }),
      _player.stream.buffering.listen((buffering) {
        if (mounted) setState(() => _isBuffering = buffering);
      }),
      _player.stream.error.listen((err) {
        if (mounted && err.isNotEmpty) {
          _addLog('播放器错误: $err', level: _LogLevel.error);
          setState(() => _error = err);
          _handlePlaybackError(err);
        }
      }),
      _player.stream.completed.listen((completed) {
        if (completed) {
          _addLog('播放完成', level: _LogLevel.success);
          _stopReporting();
        }
      }),
    ]);

    if (widget.videoUrl != null && widget.videoUrl!.isNotEmpty) {
      _openMedia(widget.videoUrl!, drmToken: widget.drmToken);
    }

    _scheduleHideControls();
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _stopReporting();
    // 回收页面内部启动的解密代理 (launcher 启动的那个由 launcher 自己回收)
    _proxy?.stop();
    _proxy = null;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _player.dispose();
    // 退出时恢复系统 UI 和方向
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ─── 播放控制 ───

  /// 打开媒体播放
  ///
  /// [drmToken] 仅对腾讯云 DRM HLS 需要。传入后会:
  ///   1. 把 token 追加到 m3u8 URL (使 m3u8 本身请求通过鉴权)
  ///   2. 设置 Origin/Referer 头 (teacher.ewt360.com, CDN 校验)
  ///      media_kit 的 [Media.httpHeaders] 会被 mpv 注入到所有 HLS 子请求
  ///      (m3u8 / TS 段 / EXT-X-KEY), 因此 DRM key 请求也会带上这些头。
  ///
  /// 若 CDN 严格要求 key URI 自身携带 token 参数 (而非 header),
  /// 此处依赖 mpv 的 http_headers 机制; 实测不行时需改为本地改写 m3u8。
  ///
  /// 对齐下载侧的 [VideoSourceResolver.appendToken] 与 [VideoSourceResolver.dlHeaders]。
  void _openMedia(String url,
      {String drmToken = '', Duration? resumeTo, List<String>? fallbacks}) {
    // 记录当前 DRM token (清晰度切换需携带同一 token)
    _activeDrmToken = drmToken;
    if (fallbacks != null) {
      // 记录阿里云线路内备用转码档 (仅线路切换/首次切入阿里云时重置)
      _aliyunFallbacks = fallbacks;
      _aliyunFallbackIndex = 0;
    }
    setState(() => _error = null);

    // 拼接 drmToken 到 m3u8 URL (对齐下载侧 _appendToken)
    final playUrl = drmToken.isEmpty
        ? url
        : VideoSourceResolver.appendToken(url, drmToken);

    // 鉴权请求头 (对齐 VideoSourceResolver.dlHeaders, CDN 校验 Origin)
    final cfg = getIt<EndpointConfig>();
    final httpHeaders = <String, String>{
      'User-Agent': cfg.userAgent,
      ...ApiHeaders.teacher,
      'Accept': '*/*',
      ...cfg.extraHeaders,
    };

    _player.open(Media(playUrl, httpHeaders: httpHeaders));
    _addLog('打开媒体: ${playUrl.length > 80 ? '${playUrl.substring(0, 80)}...' : playUrl}'
        '${drmToken.isNotEmpty ? ' (DRM)' : ''}');
    _startReporting();
    if (resumeTo != null && resumeTo > Duration.zero) {
      // 切换线路等场景: 从本地进度继续 (而非服务端进度)
      _seekWhenReady(resumeTo);
    } else {
      // 获取服务端已播放进度, 视频加载后从该位置继续播放
      _resumeFromServerProgress();
    }
  }

  /// 切换播放线路 (腾讯云/阿里云/自动)
  ///
  /// 用原始 [widget.videoInfo] 重新解析目标线路, 成功后从当前进度继续播放。
  /// 解析失败时回退到"自动"线路并提示, 不影响本次播放。
  Future<void> _switchLine(VideoLine line) async {
    final info = widget.videoInfo;
    final resolver = _resolver;
    // 无 videoInfo 或已处于目标线路, 或正在切换时不处理
    if (info == null || info.isEmpty || resolver == null || line == _line) {
      return;
    }
    if (_lineSwitching) return;

    final resumeTo = _position;
    setState(() {
      _line = line; // 立即更新显示
      _lineSwitching = true;
    });
    _addLog('切换线路 → ${_lineName(line)}, 解析中...');

    try {
      final source = await resolver.resolve(info, line: line);
      if (!mounted) return;
      if (source == null || source.url.isEmpty) {
        setState(() {
          _line = VideoLine.auto;
          _lineSwitching = false;
        });
        _showSnackBar('「${_lineName(line)}」线路解析失败, 已回退自动线路');
        _addLog('「${_lineName(line)}」线路解析失败, 已回退自动线路',
            level: _LogLevel.warning);
        return;
      }
      setState(() {
        _lineSwitching = false;
        // 记录实际线路 (auto 时 resolve 内部可能落到阿里云/腾讯云),
        // 这样 error 监听才能依据真实来源做自动回退, 而非始终停在 auto。
        if (source.line != VideoLine.auto) _line = source.line;
        // 同步新线路的清晰度档位 (首项 = 默认)
        if (source.qualities.isNotEmpty) {
          _qualities = source.qualities;
          _qualityIndex = 0;
        }
      });
      // 私有加密线路: 起本地解密代理 (mpv 无法解样本级加密)
      var openUrl = source.url;
      if (source.aliyunEncrypted && !kIsWeb) {
        await _proxy?.stop();
        _proxy = null;
        try {
          final proxy = await AliyunHlsProxy.start(
            qualities: source.qualities,
            headers: resolver.dlHeaders,
          );
          _proxy = proxy;
          openUrl = proxy.playlistUrl;
          if (mounted) {
            setState(() {
              _qualities = proxy.qualities;
              _qualityIndex = 0;
            });
          }
        } catch (e) {
          _addLog('解密代理启动失败, 直连: $e', level: _LogLevel.warning);
        }
      }

      final actual = source.line != VideoLine.auto ? source.line : line;
      _openMedia(openUrl,
          drmToken: source.drmToken,
          resumeTo: resumeTo,
          fallbacks: source.fallbacks);
      _addLog('线路切换成功 → ${_lineName(actual)}, 从 ${_formatDuration(resumeTo)} 继续',
          level: _LogLevel.success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _line = VideoLine.auto;
        _lineSwitching = false;
      });
      _showSnackBar('线路切换失败: $e');
      _addLog('线路切换异常: $e', level: _LogLevel.error);
    }
  }

  static String _lineName(VideoLine l) => switch (l) {
        VideoLine.auto => '自动',
        VideoLine.tencent => '腾讯云',
        VideoLine.aliyun => '阿里云',
      };

  // ─── 清晰度切换 ───

  /// 切换清晰度档位 (同线路内换 URL, 从当前进度继续播放)
  ///
  /// 腾讯云 DRM 档位需携带同一 drmToken; 阿里云 MP4 直链无 token。
  void _switchQuality(int idx) {
    if (idx < 0 || idx >= _qualities.length || idx == _qualityIndex) return;
    final target = _qualities[idx];
    final resumeTo = _position;
    setState(() => _qualityIndex = idx);
    _addLog(
        '切换清晰度 → ${target.label}, 从 ${_formatDuration(resumeTo)} 继续');
    _openMedia(target.url, drmToken: _activeDrmToken, resumeTo: resumeTo);
  }

  // ─── 播放错误自动回退 ───

  /// 统一处理播放器错误, 对已知可控错误做自动回退
  ///
  /// 目前处理: 阿里云线路的音频解码错误 (如 "Error decoding audio")。
  /// media_kit/mpv 对部分阿里云"原片"MP4 的音轨编码支持不足时会报此错,
  /// 此时在**阿里云线路内部**换成已转码的备用码流重新播放 (不做跨线路回退)。
  void _handlePlaybackError(String err) {
    if (_line == VideoLine.aliyun &&
        err.toLowerCase().contains('error decoding audio')) {
      _handleAliyunAudioDecodeError();
    }
  }

  /// 阿里云线路音频解码失败 → 在同线路内切换下一个转码档重试
  ///
  /// 真正修复阿里云解码问题: 不切换到腾讯云, 而是利用 [VideoSourceResolver]
  /// 返回的 [ResolvedVideoSource.fallbacks] (已转码码流, H.264+AAC) 降档重播,
  /// 从根源规避 mpv 对原片音轨的解码失败。每一档只尝试一次, 全部失败才提示。
  Future<void> _handleAliyunAudioDecodeError() async {
    if (_aliyunAudioFallbackDone) return;
    _aliyunAudioFallbackDone = true;

    final fb = _aliyunFallbacks;
    if (fb.isEmpty) {
      _showSnackBar('阿里云线路音频解码失败, 且无可用转码备用源');
      _addLog('阿里云线路音频解码失败, 无可用转码备用源',
          level: _LogLevel.warning);
      _aliyunAudioFallbackDone = false;
      return;
    }

    // 当前首选(或已换到的档)解码失败, 尝试下一档
    if (_aliyunFallbackIndex >= fb.length - 1) {
      _showSnackBar('阿里云线路音频解码失败, 所有转码档均不可用');
      _addLog('阿里云线路音频解码失败, 所有转码档均不可用',
          level: _LogLevel.warning);
      _aliyunAudioFallbackDone = false;
      return;
    }
    _aliyunFallbackIndex++;
    final next = fb[_aliyunFallbackIndex];
    _addLog('阿里云线路当前源音频解码失败, 切换到备用转码档 ${_aliyunFallbackIndex + 1}/${fb.length}...',
        level: _LogLevel.warning);
    _showSnackBar(
        '阿里云线路音频格式不兼容, 已自动切换备用转码档 ${_aliyunFallbackIndex + 1}/${fb.length}');

    final resumeTo = _position;
    // 换档重开 (不重置 finder, 交由下一档; 有限次数, 不会无限循环)
    await _player.stop();
    _openMedia(next, resumeTo: resumeTo);
    _aliyunAudioFallbackDone = false;
  }

  /// 等待时长就绪后 seek 到指定位置
  ///
  /// 供线路切换后续播: [Player.open] 后需要等 duration 可用才能 seek。
  /// 轮询至多 5 秒 (50 × 100ms), 超时放弃。
  Future<void> _seekWhenReady(Duration target) async {
    for (var i = 0; i < 50; i++) {
      if (!mounted) return;
      if (_duration > Duration.zero) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || _duration == Duration.zero) return;
    if (target < _duration) _player.seek(target);
  }

  /// 获取服务端已播放进度并从该位置继续播放
  ///
  /// 对齐 Web 播放器行为: 进入页面时调用 getUserHomeworkLessonTaskInfo
  /// 获取 playTime (已播放毫秒), 视频加载后 seek 到该位置。
  ///
  /// 行为受 [ReportConfig.resumeFromServer] 控制 (默认 true):
  /// - 开启: 真实播放器 seek 到服务端 playTime 位置 (让用户从上次进度观看)
  /// - 关闭: 不 seek, 从 0 开始播放
  ///
  /// 注: 快刷模式的进度上报续刷由 [PlaybackEngine] 内部处理, 与此处真实播放器 seek 互相独立。
  /// 周培优场景无 homeworkId, 接口要求作业ID非空, 故跳过续播从 0 开始
  /// (对齐 Python: homework_id 为 None 时 _execute_resume_playtime_ms 保持 0)。
  void _resumeFromServerProgress() {
    final session = widget.session;
    final config = widget.reportConfig ?? const ReportConfig();
    // 用户关闭"从上次进度开始"时不 seek
    if (session == null || !config.resumeFromServer) return;
    // 周培优无 homeworkId, 接口要求作业ID非空, 跳过续播
    if (session.homeworkId.isEmpty) {
      _addLog('[续播] 无作业ID, 从头播放 (周培优场景)');
      return;
    }

    final client = getIt<DioClient>();
    final playerRemote = PlayerRemoteDataSource(client);

    // 异步获取服务端进度, 不阻塞 UI
    playerRemote
        .getLessonTaskInfo(
          homeworkId: session.homeworkId,
          lessonId: session.lessonId,
          contentType: session.contentType,
          schoolId: session.schoolId,
        )
        .then((info) {
      if (!mounted || _duration == Duration.zero) return;
      // 优先使用 finishPlayTime (实际观看到的最后位置, ≤ lessonTime)
      // playTime 是累积观看时长, 可能 > lessonTime (多次观看/回放累积), 不适合作为 seek 位置
      final finishMs = info['finishPlayTime'];
      final playMs = info['playTime'];
      final rawMs = (finishMs is num && finishMs > 0)
          ? finishMs
          : (playMs is num ? playMs : 0);
      if (rawMs > 0) {
        final resumePos = Duration(milliseconds: rawMs.toInt());
        // 仅在进度小于总时长时 seek (避免 seek 到结尾)
        if (resumePos < _duration) {
          _player.seek(resumePos);
          _addLog('[续播] 从服务端进度 ${_formatDuration(resumePos)} 继续'
              '${config.fastBrush2 ? ' (快刷模式2: 多session预算乘法)' : config.fastBrush ? ' (快刷模式: 引擎并行上报)' : ''}');
        }
      }
    }).catchError((e) {
      // 获取进度失败不影响播放
      _addLog('[续播] 获取服务端进度失败: $e', level: _LogLevel.warning);
    });
  }

  void _togglePlay() {
    _player.playOrPause();
    _scheduleHideControls();
  }

  void _seekForward() {
    final newPos = _position + const Duration(seconds: 10);
    final clamped = newPos > _duration ? _duration : newPos;
    _player.seek(clamped);
    _showControlsBriefly();
    _reportSeek(clamped);
  }

  void _seekBackward() {
    final newPos = _position - const Duration(seconds: 10);
    final clamped = newPos < Duration.zero ? Duration.zero : newPos;
    _player.seek(clamped);
    _showControlsBriefly();
    _reportSeek(clamped);
  }

  void _seekTo(Duration position) {
    _player.seek(position);
    _scheduleHideControls();
    _reportSeek(position);
  }

  // ─── 全屏 ───

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // 移动端全屏时锁定横屏
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // 退出全屏: 恢复设备默认方向 (允许所有方向)
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    _scheduleHideControls();
  }

  // ─── 音量 ───

  void _setVolume(double v) {
    setState(() => _volume = v);
    _player.setVolume(v);
  }

  // ─── 倍速 ───

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _player.setRate(s);
    // 动态更新后台上报引擎的倍速 (对齐 Web 播放器倍速切换事件)
    if (_engine != null && _engineRunning) {
      _engine!.setSpeed(s);
      _addLog('[上报] 倍速切换为 ${s}x, 后续上报已同步');
    }
  }

  // ─── 画中画 ───

  Future<void> _checkPipAvailability() async {
    // kIsWeb 短路: dart:io Platform 在 Web 端访问会抛 UnsupportedError
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final available =
          await _pipChannel.invokeMethod<bool>('isAvailable') ?? false;
      if (mounted) setState(() => _pipAvailable = available);
    } catch (_) {}
  }

  Future<void> _enterPip() async {
    if (!Platform.isAndroid) {
      _showSnackBar('画中画仅在 Android 平台可用');
      return;
    }
    try {
      final ok = await _pipChannel.invokeMethod<bool>('enter') ?? false;
      if (!ok) {
        _showSnackBar('当前设备不支持画中画');
      } else {
        _addLog('已进入画中画模式', level: _LogLevel.success);
      }
    } catch (e) {
      _showSnackBar('画中画启动失败: $e');
    }
  }

  // ─── 粘贴播放 ───

  Future<void> _pasteAndPlay() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showSnackBar('剪贴板为空');
      return;
    }
    if (!text.startsWith('http') && !text.startsWith('rtsp')) {
      _showSnackBar('剪贴板内容不是有效的媒体链接');
      return;
    }
    _openMedia(text);
  }

  // ─── 截图 ───

  Future<void> _takeScreenshot() async {
    // 检查视频是否已加载
    if (_duration == Duration.zero) {
      _showSnackBar('请先加载视频再截图');
      return;
    }
    try {
      final Uint8List? bytes = await _player.screenshot();
      if (bytes == null || bytes.isEmpty) {
        _showSnackBar('截图失败: 播放器未返回画面数据');
        return;
      }
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'ewt_screenshot_$timestamp.png';
      // Web: 无文件系统, 通过浏览器下载; Native: 写下载目录
      final path = kIsWeb
          ? await WebFileSaver.saveBytes(filename, bytes)
          : await () async {
              final dir = await getDownloadsDirectory() ??
                  await getApplicationDocumentsDirectory();
              final saveDir = Directory('${dir.path}/EwtAutoClient/截图');
              if (!saveDir.existsSync()) saveDir.createSync(recursive: true);
              final file = File('${saveDir.path}/$filename');
              await file.writeAsBytes(bytes);
              return file.path;
            }();
      _showSnackBar('截图已保存: $path');
      _addLog('截图: $path', level: _LogLevel.success);
    } catch (e) {
      _showSnackBar('截图失败: $e');
      _addLog('截图异常: $e', level: _LogLevel.error);
    }
  }

  // ─── 字幕 (待开发) ───

  void _showSubtitleTodo() {
    _showSnackBar('字幕功能待开发');
  }

  // ─── 进度上报 (后台 PlaybackEngine) ───

  /// 启动后台进度上报
  ///
  /// 对应 Python: VideoPlayerDialog 在播放视频时后台运行 PlayerBehaviorTask
  ///
  /// 当 [widget.session] 和 [widget.reportConfig] 均非空时, 创建 PlaybackEngine
  /// 并调用 simulatePlayback 在后台上报进度. 引擎与真实播放并行执行, 互不阻塞.
  /// 引擎的 progressStream 事件实时显示在日志 Drawer 中。
  ///
  /// 用户切换倍速/seek 时, 通过 [PlaybackEngine.setSpeed] / [reportSeek]
  /// 实时同步到引擎, 对齐 Web 播放器的事件驱动上报。
  void _startReporting() {
    if (widget.session == null) {
      // 无 session: 仅记录播放进度日志 (无服务端上报)
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
        _addLog('[上报] 进度上报完成', level: _LogLevel.success);
        _engineRunning = false;
      } else if (progress.state == PlaybackState.failed ||
          progress.state == PlaybackState.cancelled) {
        _engineRunning = false;
      }
    });

    _engineRunning = true;
    _addLog('[上报] 后台进度上报已启动', level: _LogLevel.success);

    // 后台启动 simulatePlayback (不阻塞 UI)
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
      if (mounted) {
        _addLog('[上报] 引擎异常: $e', level: _LogLevel.error);
      }
      _engineRunning = false;
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

  /// 上报 seek 事件 (用户快进/快退/拖动进度条)
  ///
  /// 对齐 Web 播放器 seek 事件: 发送 playbackProgress 上报当前实际位置。
  void _reportSeek(Duration position) {
    if (_engine == null || !_engineRunning) return;
    _engine!.reportSeek(position.inSeconds).then((_) {
      _addLog('[上报] seek → ${_formatDuration(position)}');
    }).catchError((e) {
      _addLog('[上报] seek 上报失败: $e', level: _LogLevel.warning);
    });
  }

  void _addLog(String message, {_LogLevel level = _LogLevel.info}) {
    if (!mounted) return;
    setState(() {
      _reportLogs.add(_LogEntry(
        message: message,
        level: level,
        time: DateTime.now(),
      ));
      if (_reportLogs.length > 200) _reportLogs.removeAt(0);
    });
  }

  // ─── 控制栏显隐 ───

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() => _showControls = true);
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying) setState(() => _showControls = false);
    });
  }

  void _showControlsBriefly() => _scheduleHideControls();

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
                if (_pipAvailable &&
                    RiskControlGate.isFeatureEnabled('player.pip'))
                  IconButton(
                    icon: const Icon(Icons.picture_in_picture_alt_outlined),
                    tooltip: '画中画',
                    onPressed: _enterPip,
                  ),
                IconButton(
                  icon: const Icon(Icons.subtitles),
                  tooltip: '字幕 (待开发)',
                  onPressed: _showSubtitleTodo,
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
            // 视频画面
            Video(
              controller: _videoController,
              controls: NoVideoControls,
            ),

            // 错误提示
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

            // 无视频时的粘贴提示
            if (_duration == Duration.zero && _error == null && !_isBuffering)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.movie_outlined,
                        color: Colors.white.withValues(alpha: 0.3), size: 64),
                    const SizedBox(height: 16),
                    Text(
                      '暂无视频',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 16),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _pasteAndPlay,
                      icon: const Icon(Icons.paste, size: 18),
                      label: const Text('粘贴链接播放'),
                    ),
                  ],
                ),
              ),

            // 缓冲指示器
            if (_isBuffering)
              const Center(child: CircularProgressIndicator()),

            // 全屏时的顶部操作栏
            if (_isFullscreen)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back,
                                color: Colors.white),
                            onPressed: _toggleFullscreen,
                          ),
                          Expanded(
                            child: Text(
                              widget.title,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 15),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.camera_alt_outlined,
                                color: Colors.white),
                            tooltip: '截图',
                            onPressed: _takeScreenshot,
                          ),
                          if (_pipAvailable)
                            IconButton(
                              icon: const Icon(
                                  Icons.picture_in_picture_alt_outlined,
                                  color: Colors.white),
                              tooltip: '画中画',
                              onPressed: _enterPip,
                            ),
                          if (widget.videoInfo != null && widget.videoInfo!.isNotEmpty)
                            _LineButton(
                              line: _line,
                              switching: _lineSwitching,
                              onSelected: _switchLine,
                              compact: true,
                            ),
                          IconButton(
                            icon: const Icon(
                              Icons.subtitles,
                              color: Colors.white,
                            ),
                            tooltip: '字幕 (待开发)',
                            onPressed: _showSubtitleTodo,
                          ),
                          IconButton(
                            icon: const Icon(Icons.receipt_long_outlined,
                                color: Colors.white),
                            tooltip: '上报日志',
                            onPressed: () => _scaffoldKey.currentState
                                ?.openEndDrawer(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

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

  // ─── 底部控制栏 (响应式: 移动端窄屏自动简化) ───

  Widget _buildControlBar(ThemeData theme) {
    // 竖屏 (移动端未全屏): 底部极致简化 — 仅保留 播放/暂停 与 横屏全屏 按钮
    final minimalPortrait = _isMobile && !_isFullscreen;
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, _isFullscreen ? 16 : 8),
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
            _buildProgressSlider(theme),
            const SizedBox(height: 2),
            // 按钮行: 竖屏极简 (播放/暂停 + 全屏); 其余场景全量/自动简化
            LayoutBuilder(
              builder: (context, constraints) {
                if (minimalPortrait) {
                  return Row(
                    children: [
                      _playPauseButton(),
                      const Spacer(),
                      _fullscreenButton(),
                    ],
                  );
                }
                // 全屏时展示全部元素; 非全屏 + 宽屏 (桌面) 展示全部
                final showAll =
                    _isFullscreen || constraints.maxWidth >= 600;
                return Row(
                  children: [
                    // 时间 (固定宽度避免文本过长时挤压按钮)
                    SizedBox(
                      width: 100,
                      child: Text(
                        '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // 快退 10s (非核心, 窄屏隐藏)
                    if (showAll)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 36, minHeight: 36),
                        icon: const Icon(Icons.replay_10, color: Colors.white),
                        tooltip: '快退10秒',
                        onPressed: _seekBackward,
                      ),
                    _playPauseButton(),
                    // 快进 10s (非核心, 窄屏隐藏)
                    if (showAll)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 36, minHeight: 36),
                        icon: const Icon(Icons.forward_10, color: Colors.white),
                        tooltip: '快进10秒',
                        onPressed: _seekForward,
                      ),
                    const Spacer(),
                    // 线路切换 (提供 videoInfo 时可用)
                    if (widget.videoInfo != null && widget.videoInfo!.isNotEmpty)
                      _LineButton(
                        line: _line,
                        switching: _lineSwitching,
                        onSelected: _switchLine,
                      ),
                    // 清晰度 (解析结果多于一项时可用)
                    if (_qualities.length > 1)
                      _QualityButton(
                        qualities: _qualities,
                        current: _qualityIndex,
                        onSelected: _switchQuality,
                      ),
                    // 倍速 (核心, 始终展示)
                    _SpeedButton(
                      speed: _speed,
                      onSelected: _setSpeed,
                    ),
                    // 音量 (非核心, 窄屏隐藏)
                    if (showAll)
                      _VolumeButton(
                        volume: _volume,
                        onChanged: _setVolume,
                      ),
                    _fullscreenButton(),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 进度条
  Widget _buildProgressSlider(ThemeData theme) {
    return SliderTheme(
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
        value: _duration.inMilliseconds > 0
            ? (_position.inMilliseconds / _duration.inMilliseconds)
                .clamp(0.0, 1.0)
            : 0.0,
        onChanged: (v) {
          if (_duration > Duration.zero) {
            _seekTo(Duration(
                milliseconds:
                    (v * _duration.inMilliseconds).round()));
          }
        },
      ),
    );
  }

  /// 播放/暂停按钮
  Widget _playPauseButton() {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      iconSize: 38,
      icon: Icon(
        _isPlaying
            ? Icons.pause_circle_filled
            : Icons.play_circle_filled,
        color: Colors.white,
      ),
      onPressed: _togglePlay,
    );
  }

  /// 全屏/退出全屏按钮
  ///
  /// 竖屏 (未全屏) 时显示"全屏"用于切回横屏全屏; 全屏时显示"退出全屏"。
  Widget _fullscreenButton() {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      icon: Icon(
        _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
        color: Colors.white,
      ),
      tooltip: _isFullscreen ? '退出全屏' : '横屏全屏',
      onPressed: _toggleFullscreen,
    );
  }

  // ─── 日志 Drawer ───

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

            // 日志列表
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

  // ─── Helpers ───

  String _formatDuration(Duration d) {
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

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}

// ─── 倍速按钮 ───

class _SpeedButton extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onSelected;

  const _SpeedButton({required this.speed, required this.onSelected});

  static const _options = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary)
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

class _VolumeButton extends StatelessWidget {
  final double volume;
  final ValueChanged<double> onChanged;

  const _VolumeButton({required this.volume, required this.onChanged});

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
                          : volume < 50
                              ? Icons.volume_down
                              : Icons.volume_up,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text('${volume.toInt()}%'),
                  ],
                ),
                Slider(
                  value: volume,
                  min: 0,
                  max: 100,
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
              : volume < 50
                  ? Icons.volume_down
                  : Icons.volume_up,
          color: Colors.white,
          size: 22,
        ),
      ),
    );
  }
}

// ─── 线路切换按钮 ───

class _LineButton extends StatelessWidget {
  final VideoLine line;
  final bool switching;
  final ValueChanged<VideoLine> onSelected;

  /// 是否紧凑模式 (全屏顶部栏: 仅图标)
  final bool compact;

  const _LineButton({
    required this.line,
    required this.switching,
    required this.onSelected,
    this.compact = false,
  });

  static String _name(VideoLine l) => switch (l) {
        VideoLine.auto => '自动',
        VideoLine.tencent => '腾讯云',
        VideoLine.aliyun => '阿里云',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _name(line);

    // 切换中: 显示加载指示, 不可点
    if (switching) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: compact ? Colors.white : theme.colorScheme.primary,
            ),
          ),
        ),
      );
    }

    return PopupMenuButton<VideoLine>(
      tooltip: '线路: $current',
      offset: const Offset(0, -160),
      initialValue: line,
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        for (final l in VideoLine.values)
          PopupMenuItem<VideoLine>(
            value: l,
            child: Row(
              children: [
                if (l == line)
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(_name(l)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: compact
            ? const Icon(Icons.compare_arrows, color: Colors.white, size: 20)
            : Text(
                current,
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

// ─── 清晰度切换按钮 ───

class _QualityButton extends StatelessWidget {
  final List<ResolvedVideoQuality> qualities;
  final int current;
  final ValueChanged<int> onSelected;

  const _QualityButton({
    required this.qualities,
    required this.current,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(qualities[i].label),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
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

// ─── 辅助类 ───

class _LogEntry {
  final String message;
  final _LogLevel level;
  final DateTime time;

  const _LogEntry({
    required this.message,
    required this.level,
    required this.time,
  });
}

enum _LogLevel { info, success, warning, error }
