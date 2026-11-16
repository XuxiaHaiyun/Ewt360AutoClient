/// 视频播放启动器：统一封装"解析视频源 → 获取 BFE 会话 → 跳转播放页 + 后台进度上报"
/// 流程，供课程详情/周培优任务详情共用。Web 端按 kIsWeb 分发到 HTML5 播放页。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../auth/domain/entities/user_session.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../domain/entities/video_session.dart';
import '../../domain/services/aliyun_hls_proxy.dart';
import '../../domain/services/video_source_resolver.dart';
import '../pages/report_config_page.dart';
import '../pages/video_player_page.dart';
import '../pages/web_video_player_page.dart';

/// 视频播放启动器
///
/// 统一封装"真实播放视频 + 后台进度上报"流程, 供课程详情/周培优任务详情共用:
/// 1. 打开 [ReportConfigPage] 获取上报配置 (取消则不播放)
/// 2. 调用 [VideoSourceResolver] 解析真实播放地址 (腾讯云/阿里云)
/// 3. 获取 BFE 会话配置 ([PlayerRemoteDataSource.getPlayerGlobalConf]) 构建 [VideoSession]
/// 4. 跳转 [VideoPlayerPage], 携带 session + reportConfig 启用后台上报 + 日志侧边栏
///
/// 对应 Python: gui/dialogs/player.py VideoPlayerDialog 中真实播放 + 后台 PlayerBehaviorTask 并行。
class VideoPlayLauncher {
  VideoPlayLauncher._();

  /// 启动视频播放 + 后台进度上报
  ///
  /// [videoInfo] [PlayerRemoteDataSource.getExternalVideoInfo] 返回的完整 Map (含 videoList),
  ///              由调用方预先获取并传入。
  /// [lessonId] 讲次 ID (getPlayerToken / VideoSession 必传)。
  /// [homeworkId] 作业 ID (周培优可为空字符串)。
  /// [videoId] 视频 ID (为空时回退使用 lessonId)。
  /// [taskId] 任务 ID (refreshTaskProgress 必传, 可为空)。
  /// [contentType] 内容类型 (1=视频 / 4=微专题, 默认 1)。
  /// [duration] 视频时长秒 (0 时引擎自动解析)。
  /// [title] 视频标题。
  /// [userSession] 用户会话 (提供 userId/token/provinceCode/schoolId)。
  static Future<void> start({
    required BuildContext context,
    required Map<String, dynamic> videoInfo,
    required String lessonId,
    String homeworkId = '',
    String videoId = '',
    String taskId = '',
    int contentType = 1,
    int duration = 0,
    required String title,
    required UserSession? userSession,
  }) async {
    // Web 平台不支持 media_kit (依赖 native mpv), 使用 Web 播放器
    // (HTML5 <video>) 播放阿里云 MP4 直链; 腾讯云 DRM HLS 受浏览器
    // Origin 头不可覆盖限制暂不支持, 故 Web 端强制阿里云线路解析。
    final isWeb = kIsWeb;

    if (videoInfo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未获取到视频源信息')),
      );
      return;
    }

    // 提前捕获 root navigator 与 messenger, 避免 await 后再依赖 context。
    //
    // 关键: 调用方 context 可能来自 ShellRoute 的内层 navigator (如周培优页面本身),
    // 而 showDialog 默认挂在 root navigator 上。若用 Navigator.of(context).pop()
    // 关闭加载弹窗, 实际 pop 的是内层 navigator, 加载弹窗 (barrier + canPop:false)
    // 会永远停留在最上层 => 表现为"黑屏卡死"。
    // 同理 VideoPlayerPage 也必须 push 到 root navigator, 否则会被弹窗 barrier 遮住。
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    // 1. 打开上报配置页 (取消则不播放)
    final config = await ReportConfigPage.show(context);
    if (config == null || !context.mounted) return;

    // 2. 显示加载指示器 (解析视频源 + 获取 BFE 会话 并行)
    final closeLoading =
        _showLoadingDialog(context, '正在解析视频源并准备上报...');

    try {
      final client = getIt<DioClient>();
      final resolver = VideoSourceResolver(client: client);
      final playerRemote = PlayerRemoteDataSource(client);

      // 并行: 解析视频源 + 获取 BFE 会话
      // (Web 强制阿里云线路: 只有阿里云返回浏览器可直接播放的 MP4 直链)
      final results = await Future.wait([
        resolver.resolve(videoInfo, line: isWeb ? VideoLine.aliyun : VideoLine.auto),
        _fetchBfeSession(playerRemote),
      ]);
      final source = results[0] as ResolvedVideoSource?;
      final bfe = results[1] as _BfeSession;

      closeLoading(); // 关闭加载弹窗 (使用弹窗自身 context, 不受 Shell 内层 navigator 影响)

      if (source == null || source.url.isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(isWeb
                ? '解析播放地址失败 (Web 端仅支持阿里云线路的 MP4 视频)'
                : '解析播放地址失败 (腾讯云/阿里云均失败)'),
          ),
        );
        return;
      }

      // ── 阿里云私有加密: 起本地解密代理 ──
      //
      // 私有加密是样本级加密 (TS 容器明文, PES 负载 AES-128-ECB), mpv 没有
      // 对应滤镜, 直接播只有乱码。AliyunHlsProxy 在 127.0.0.1 上伪装成普通
      // HLS 源: 按需拉段 → 本地解密 → 回吐明文 TS, 从而边下边播 (可 seek)。
      //
      // Web 端不能起 HttpServer, 只能提示改用客户端。
      AliyunHlsProxy? proxy;
      String playUrl = source.url;
      List<ResolvedVideoQuality> qualities = source.qualities;
      if (source.aliyunEncrypted) {
        if (isWeb) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                  '该视频仅提供加密的阿里云线路, Web 端暂不支持播放, 请使用 Windows / Android 客户端'),
              duration: Duration(seconds: 4),
            ),
          );
          return;
        }
        try {
          proxy = await AliyunHlsProxy.start(
            qualities: source.qualities,
            headers: resolver.dlHeaders,
          );
          playUrl = proxy.playlistUrl;
          // 清晰度列表也换成代理地址, 切档同样走解密
          qualities = proxy.qualities;
        } catch (e) {
          // 代理起不来不阻断: 退回原地址 (画面会是乱码, 但至少能报出具体原因)
          messenger.showSnackBar(
            SnackBar(content: Text('解密代理启动失败, 将尝试直连: $e')),
          );
        }
      }

      // 3. 构建 VideoSession (携带 BFE CommonPackage 所需用户/环境上下文)
      //    V7: injectUserId 开启时 CommonPackage.userid 覆盖为注入目标
      final session = VideoSession(
        homeworkId: homeworkId,
        lessonId: lessonId,
        videoId: videoId.isNotEmpty ? videoId : lessonId,
        taskId: taskId,
        contentType: contentType,
        schoolId: userSession?.schoolId ?? '',
        sessionId: bfe.sessionId,
        secret: bfe.secret,
        duration: duration,
        userId: config.effectiveInjectUserId ?? userSession?.userId ?? '',
        token: userSession?.token ?? '',
        clientIp: bfe.clientIp,
        memberProvinceCode: userSession?.provinceCode ?? '',
        schoolProvinceCode: userSession?.provinceCode ?? '',
      );

      // 4. 跳转播放页 (携带 session + reportConfig 启用后台上报 + 日志侧边栏)
      //    必须使用 root navigator: 否则从页面 (ShellRoute 内层) 打开时会被
      //    底部导航遮挡, 且返回时与 ShellRoute 状态冲突。
      //    Web: 使用 HTML5 <video> 播放器 (media_kit/mpv 不可用)。
      final route = MaterialPageRoute(
        builder: (_) => isWeb
            ? WebVideoPlayerPage(
                videoUrl: playUrl,
                initialQualities: qualities,
                title: title,
                lessonId: lessonId,
                session: session,
                reportConfig: config,
              )
            : VideoPlayerPage(
                videoUrl: playUrl,
                drmToken: source.drmToken,
                videoInfo: videoInfo,
                initialQualities: qualities,
                title: title,
                lessonId: lessonId,
                session: session,
                reportConfig: config,
              ),
      );
      // 播放页关闭后回收代理 (释放端口与缓存)
      rootNavigator.push(route).whenComplete(() {
        proxy?.stop();
      });
    } catch (e) {
      closeLoading(); // 关闭加载弹窗
      messenger.showSnackBar(
        SnackBar(content: Text('播放失败: $e')),
      );
    }
  }

  /// 显示不可关闭的加载弹窗, 返回"关闭弹窗"的回调
  ///
  /// 回调内部通过弹窗自身的 context 关闭, 因此无论调用方处于哪一层 navigator
  /// (root / ShellRoute 内层) 都能正确关闭, 且重复调用安全。
  static VoidCallback _showLoadingDialog(
      BuildContext context, String message) {
    BuildContext? dialogContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        dialogContext = ctx;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 20),
                Expanded(child: Text(message)),
              ],
            ),
          ),
        );
      },
    );

    var closed = false;
    void close() {
      if (closed) return;
      final ctx = dialogContext;
      if (ctx == null) {
        // 弹窗尚未完成首帧构建 (极端快速返回场景), 延后到下一帧再关闭
        WidgetsBinding.instance.addPostFrameCallback((_) => close());
        return;
      }
      closed = true;
      if (ctx.mounted) Navigator.of(ctx).pop();
    }

    return close;
  }

  /// 获取 BFE 会话配置 (getPlayerGlobalConf)
  ///
  /// sessionId / secret / clientIp 是 BFE CommonPackage 必传字段, per-user 维度。
  /// 失败时使用默认值, 不阻断流程。对齐 [ProgressReportService._ensureBfeSession]。
  static Future<_BfeSession> _fetchBfeSession(
      PlayerRemoteDataSource playerRemote) async {
    String sessionId = '';
    String secret = '';
    String clientIp = '';

    try {
      final globalConf = await playerRemote.getPlayerGlobalConf().timeout(
        const Duration(seconds: 15),
        onTimeout: () => <String, dynamic>{},
      );
      final globalInfo =
          (globalConf['globalInfo'] as Map<String, dynamic>?) ?? {};
      sessionId = globalInfo['sessionId']?.toString() ??
          globalConf['sessionId']?.toString() ??
          '';
      secret = globalInfo['secret']?.toString() ??
          globalConf['secret']?.toString() ??
          '';
      clientIp = globalInfo['clientIp']?.toString() ??
          globalConf['clientIp']?.toString() ??
          '';
    } catch (_) {
      // 使用默认值
    }

    // sessionId 为空时生成随机值 (BFE 要求非空)
    if (sessionId.isEmpty) {
      final r = Random();
      sessionId =
          List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
    }

    return _BfeSession(sessionId: sessionId, secret: secret, clientIp: clientIp);
  }
}

/// BFE 会话配置 (getPlayerGlobalConf 提取)
class _BfeSession {
  final String sessionId;
  final String secret;
  final String clientIp;

  const _BfeSession({
    required this.sessionId,
    required this.secret,
    required this.clientIp,
  });
}
