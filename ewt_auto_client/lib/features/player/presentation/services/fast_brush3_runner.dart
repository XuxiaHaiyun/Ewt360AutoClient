/// 快刷模式 3 执行器（多操作者批量注入）：每个操作者账户持有独立 token/BFE session，
/// 每轮 barrier 并发注入并轮换 bfe/clog/dlog 端点，pti 窗口预算内不重复；
/// 达到完成阈值或最大轮数即停。操作者 token 失效时按登录方式自动重登或跳过。
library;

import 'dart:async';
import 'dart:math';

import '../../../../core/captcha/captcha_models.dart' show CaptchaRequiredException;
import '../../../../core/captcha/captcha_service.dart';
import '../../../../core/config/endpoint_config.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/network/dio_client.dart';
import '../../../auth/data/datasources/account_storage.dart';
import '../../../auth/data/datasources/auth_remote_datasource.dart';
import '../../../auth/data/repositories/auth_repository_impl.dart';
import '../../../auth/domain/entities/user_session.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';
import '../../domain/entities/report_config.dart';
import '../../domain/entities/telemetry_context.dart';
import '../dialogs/task_progress_dialog.dart';

/// 快刷模式3 执行器 (round15 多账户批量注入)
///
/// 对齐 output/app/src_demo_round15.py 端到端危害演示链:
///  ① 多操作者集群: 每个操作者账户独立 token / BFE session / secret,
///     包体 CommonPackage.userid 指向受害目标 (= 当前登录账号, 不可编辑),
///     token 仅认证不授权;
///  ② 每轮 barrier 并发注入: 每操作者 1 包, 端点轮换 bfe/clog/dlog,
///     pti = (全局包序 k % point_num) + 1 (跨轮延续, 窗口内不重复);
///  ③ pti 窗口预算: 单轮入账上限 ≈ point_num × 26s, 轮间等待窗口滚动;
///  ④ 达标即停: 每轮后查询受害目标真实进度 (victim token),
///     ratio >= completionThreshold 或达到最大轮数即结束。
///
/// 约束对齐演示脚本: stay=10s / speed=2.0 / 单事件包 / 每轮观测 15s。
///
/// 操作者账号来源: [ReportConfig.operatorUserIds] (弹窗多选)。
/// 执行前逐个检测 token 有效性:
/// - 密码登录且已记住密码: 失效用记住的密码自动重新登录 (含滑块自动求解)
///   并回写存储;
/// - 短信/扫码等其它登录方式: 仅当 token 有效时可用 (无法自动重登),
///   失效即跳过。
class FastBrush3Runner {
  final EndpointConfig _endpointConfig;
  final ReportConfig _config;

  /// 受害目标视角的数据源 (victim token): 课时详情解析 + 真实进度轮询
  final PlayerRemoteDataSource _victimPlayer;

  /// 受害目标 userid (= 当前登录账号, 包体注入目标, 不可编辑)
  final String victimUserId;

  /// 日志回调 (透传服务层日志流)
  final void Function(String msg, {LogLevel level}) log;

  /// 取消检查
  final bool Function() isCancelled;

  /// 真实进度轮询 (taskId → 0~1 ratio; 无 taskId 返回 null)
  final Future<double?> Function(String taskId) pollRatio;

  FastBrush3Runner({
    required EndpointConfig endpointConfig,
    required ReportConfig config,
    required PlayerRemoteDataSource victimPlayerRemote,
    required this.victimUserId,
    required this.log,
    required this.isCancelled,
    required this.pollRatio,
  })  : _endpointConfig = endpointConfig,
        _config = config,
        _victimPlayer = victimPlayerRemote;

  /// 操作者集群 (就位后填充)
  final List<_Fast3Operator> _operators = [];
  bool _prepared = false;

  /// 单轮注入端点 (对齐 EP_KEYS = bfe/clog/dlog 轮换)
  static const _hosts = ['bfe', 'clog', 'dlog'];

  /// 自动重登最大尝试次数 (含滑块自动求解重试)
  static const _maxLoginAttempts = 3;

  /// 每轮后观测等待秒数 (对齐 ROUND_OBS=15, ≥入账延迟)
  static const _roundObsSeconds = 15;

  /// 快刷3 单包声明 (对齐演示脚本: stay=10s, speed=2.0, 单事件)
  static const _defaultStayMs = 10000;
  static const _defaultSpeed = 2.0;

  // ─── 集群就位 ───

  /// 就位操作者集群 (幂等: 已就位直接返回)
  ///
  /// 1. 按 operatorUserIds 从 AccountStorage 解析账号 (不限登录方式,
  ///    选取时已保证密码账号可自动重登 / 其它方式 token 已验证有效);
  /// 2. 逐个检测 token 有效性: 失效时密码账号自动重登, 其它方式跳过;
  /// 3. 每操作者铸造独立 BFE 会话 (getPlayerGlobalConf, 独立 sessionId/secret)。
  ///
  /// 就位 0 个时抛异常 (无操作者无法执行多账户注入)。
  Future<int> ensurePrepared() async {
    if (_prepared) return _operators.length;
    _prepared = true;

    final all = await AccountStorage.loadAccounts();
    final byId = {for (final a in all) a.userId: a};
    final picked = <UserSession>[];
    for (final uid in _config.operatorUserIds) {
      final a = byId[uid];
      if (a == null) {
        log('操作者 $uid 不在已保存账号列表中, 已跳过', level: LogLevel.warning);
        continue;
      }
      picked.add(a);
    }
    if (picked.isEmpty) {
      throw Exception('未选取有效的操作者账号 (所选账号已不在存储中)');
    }

    log('─── 快刷3 操作者集群就位 (选取 ${picked.length} 个) ───',
        level: LogLevel.warning);
    for (final acc in picked) {
      if (isCancelled()) break;
      final name = acc.account ?? acc.displayName ?? acc.userId;
      final canRelogin = acc.loginMethod == 'password' &&
          (acc.password?.isNotEmpty ?? false);
      try {
        // 1. token 有效性检测 (getUser)
        var session = acc;
        final valid = await _checkToken(session);
        if (!valid) {
          if (!canRelogin) {
            log('  ✗ $name token 无效且非密码登录 (无法自动重登), 已跳过',
                level: LogLevel.error);
            continue;
          }
          log('  $name token 无效, 自动重新登录...', level: LogLevel.warning);
          session = await _relogin(session);
          log('  ✓ $name 重新登录成功 (新 token 已回写存储)',
              level: LogLevel.success);
        } else {
          log('  ✓ $name token 有效${canRelogin ? "" : " (${'短信/扫码登录, 无法自动重登'})"}');
        }

        // 2. 铸造独立 BFE 会话
        final op = await _mintOperator(session, _operators.length);
        _operators.add(op);
        log('  A${_operators.length} $name 会话就绪 '
            'sessionId=${_mask(op.sessionId, 8)}..., 代理=${session.proxy ?? "(直连)"}',
            level: LogLevel.success);
      } catch (e) {
        log('  ✗ $name 就位失败: $e', level: LogLevel.error);
      }
    }

    if (_operators.isEmpty) {
      throw Exception('操作者集群就位失败 (0/${picked.length}), '
          '请检查账号 token/记住的密码');
    }
    log('操作者就位 ${_operators.length}/${picked.length}',
        level: LogLevel.success);
    return _operators.length;
  }

  /// token 有效性检测 (GET getUser, 与账号列表"检测Token"同源)
  Future<bool> _checkToken(UserSession acc) async {
    try {
      final client =
          DioClient(endpointConfig: _endpointConfig, proxy: acc.proxy);
      client.token = acc.token;
      final resp = await client
          .get('/api/usercenter/user/login/getUser')
          .timeout(const Duration(seconds: 10));
      return resp.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// 自动重新登录 (密码登录, 新 token 回写 AccountStorage)
  ///
  /// 触发风控滑块 ([CaptchaRequiredException], failCode 017129/017130) 时,
  /// 调用 [CaptchaService.solveAutomatically] 自动求解滑块 (视觉预测缺口 +
  /// 局部/全图 verify 扫描), 携带 captchaToken 重试登录, 最多
  /// [_maxLoginAttempts] 次; 求解失败或重试耗尽才向上抛错。
  Future<UserSession> _relogin(UserSession acc) async {
    final password = acc.password ?? '';
    final account = acc.account ?? '';
    if (account.isEmpty || password.isEmpty) {
      throw Exception('未记住密码, 无法自动重新登录');
    }
    final client = DioClient(endpointConfig: _endpointConfig, proxy: acc.proxy);
    final repo = AuthRepositoryImpl(AuthRemoteDataSource(client), client);
    var captchaToken = '';
    for (var attempt = 1; attempt <= _maxLoginAttempts; attempt++) {
      try {
        final fresh = await repo.loginWithPassword(
          account: account,
          password: password,
          captchaToken: captchaToken.isEmpty ? null : captchaToken,
        );
        // 合并保留本地配置 (登录方式/记住密码/代理), 回写存储供下次复用
        final merged = UserSession.merge(fresh, acc);
        await AccountStorage.upsertAccount(merged);
        return merged;
      } on CaptchaRequiredException {
        if (attempt >= _maxLoginAttempts) rethrow;
        log('  $account 触发滑块验证, 自动求解滑块 (尝试 $attempt/$_maxLoginAttempts)...',
            level: LogLevel.warning);
        captchaToken = await CaptchaService().solveAutomatically();
        log('  ✓ 滑块求解通过, 重试登录 $account', level: LogLevel.success);
      }
    }
    throw Exception('自动重新登录失败: $account (重试耗尽)');
  }

  /// 铸造操作者独立 BFE 会话
  Future<_Fast3Operator> _mintOperator(UserSession session, int index) async {
    final client = DioClient(endpointConfig: _endpointConfig, proxy: session.proxy);
    client.token = session.token;
    final playerRemote = PlayerRemoteDataSource(client);
    final telemetry = TelemetryRemoteDataSource(client);

    final conf =
        await playerRemote.getPlayerGlobalConf().timeout(const Duration(seconds: 15));
    final globalInfo = (conf['globalInfo'] as Map<String, dynamic>?) ?? const {};
    final sessionId = globalInfo['sessionId']?.toString() ??
        conf['sessionId']?.toString() ??
        '';
    final secret = globalInfo['secret']?.toString() ??
        conf['secret']?.toString() ??
        '';
    final clientIp = globalInfo['clientIp']?.toString() ??
        conf['clientIp']?.toString() ??
        '';
    final fallbackIP = globalInfo['fallbackIP']?.toString() ??
        conf['fallbackIP']?.toString() ??
        '';
    if (fallbackIP.isNotEmpty) telemetry.fallbackIP = fallbackIP;
    if (sessionId.isEmpty || secret.isEmpty) {
      throw Exception('BFE 会话签发失败 (sessionId/secret 缺失)');
    }
    return _Fast3Operator(
      index: index,
      session: session,
      sessionId: sessionId,
      secret: secret,
      clientIp: clientIp,
      telemetry: telemetry,
    );
  }

  // ─── 单课时执行 ───

  /// 对单个课时执行多账户批量注入 (多轮, 达标即停)
  Future<void> runTask(
    Fast3Task task, {
    required void Function(double ratio, String? message) onProgress,
  }) async {
    if (_operators.isEmpty) {
      throw Exception('操作者集群未就位');
    }
    final threshold = _config.completionThreshold.clamp(0.05, 1.0);
    final stayMs = _config.fastBrushStayTime > 0
        ? _config.fastBrushStayTime
        : _defaultStayMs;
    final speed = _config.speed > 0 ? _config.speed : _defaultSpeed;
    final roundGap = _config.fast3RoundGap.clamp(5, 600);
    final maxRounds =
        _config.fastBrushMaxRounds > 0 ? _config.fastBrushMaxRounds : 0;

    // 1. 解析 courseId / duration / point_num (victim 视角, 对齐 round15 侦察)
    var courseId = task.lessonId;
    var durS = task.duration;
    try {
      final ld = await _victimPlayer.getLessonDetail(
        schoolId: task.schoolId,
        homeworkId: task.homeworkId,
        lessonId: task.lessonId,
      );
      final cid = ld['courseId']?.toString() ?? '';
      if (cid.isNotEmpty) courseId = cid;
      if (durS <= 0) {
        final vpt = double.tryParse(ld['videoPlayTime']?.toString() ?? '') ?? 0;
        if (vpt > 0) {
          durS = vpt > 100000 ? vpt ~/ 1000 : vpt.round();
        }
      }
    } catch (_) {}
    if (durS <= 0 && task.homeworkId.isNotEmpty) {
      try {
        final ti = await _victimPlayer.getLessonTaskInfo(
          homeworkId: task.homeworkId,
          lessonId: task.lessonId,
          contentType: task.contentType ?? 1,
          schoolId: task.schoolId,
        );
        final ms = int.tryParse(ti['lessonTime']?.toString() ?? '') ?? 0;
        if (ms > 0) durS = ms ~/ 1000;
      } catch (_) {}
    }
    // point_num = ceil(时长/60), 对齐 round15 (pn = -(-dur//60)); 未知时长回退 10
    final pointNum = durS > 0 ? max(1, (durS / 60).ceil()) : 10;

    log('─── 课时 ${task.lessonId} "${task.title}" ───', level: LogLevel.warning);
    log('  point_num=$pointNum, dur=${durS}s, 阈值=${(threshold * 100).round()}%, '
        '操作者=${_operators.length}, 轮间等待=${roundGap}s, stay=${stayMs}ms, '
        'speed=${speed}x, 受害userid=$victimUserId', level: LogLevel.warning);

    // 2. 多轮注入
    final n = _operators.length;
    final beginTs = DateTime.now().millisecondsSinceEpoch;
    var round = 0;
    var lastRatio = 0.0;
    while (!isCancelled()) {
      round++;
      if (maxRounds > 0 && round > maxRounds) {
        log('  已达最大重刷轮数 $maxRounds, 停止本课时', level: LogLevel.warning);
        break;
      }
      if (round > 1) {
        log('  [窗口滚动等待 ${roundGap}s]');
        await _sleepSeconds(roundGap);
        if (isCancelled()) break;
      }

      // 一轮注入: 每操作者 1 包, 并发 barrier, 端点轮换, pti 跨轮分布
      // (对齐 barrier_inject: k = idx + (round-1)*n, pti = (k % pn) + 1)
      final t0 = DateTime.now();
      final results = await Future.wait([
        for (var i = 0; i < n; i++)
          _sendPacket(
            _operators[i],
            k: i + (round - 1) * n,
            pointNum: pointNum,
            lessonId: task.lessonId,
            courseId: courseId,
            contentType: task.contentType ?? 1,
            beginTs: beginTs,
            stayMs: stayMs,
            speed: speed,
          ),
      ]);
      final ok = results.where((r) => r.isOk).length;
      final wall =
          (DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1);
      log('  轮$round: $ok/$n ok, 墙钟 ${wall}s');

      // 观测等待 + victim 真实进度轮询
      await _sleepSeconds(_roundObsSeconds);
      if (isCancelled()) break;
      final ratio = task.taskId.isNotEmpty ? await pollRatio(task.taskId) : null;
      if (ratio != null) {
        lastRatio = ratio;
        final msg = '轮$round: $ok/$n 包 ok, 服务端进度 ${(ratio * 100).toStringAsFixed(1)}%';
        onProgress(ratio, msg);
        log('  $msg ${ratio >= threshold ? '✓达标' : ''}',
            level: ratio >= threshold ? LogLevel.success : LogLevel.info);
        if (ratio >= threshold) {
          log('  >> 课时 ${task.lessonId} 已达完成阈值 '
              '(${(ratio * 100).toStringAsFixed(1)}% >= ${(threshold * 100).round()}%) ✔',
              level: LogLevel.success);
          break;
        }
      } else {
        onProgress(lastRatio, '轮$round: $ok/$n 包 ok (无法查询真实进度)');
        log('  真实进度查询失败 (taskId 为空或接口异常), 继续下一轮',
            level: LogLevel.warning);
      }
    }
  }

  /// 发送单包 (一个操作者一轮的一包)
  Future<CollectResult> _sendPacket(
    _Fast3Operator op, {
    required int k,
    required int pointNum,
    required String lessonId,
    required String courseId,
    required int contentType,
    required int beginTs,
    required int stayMs,
    required double speed,
  }) async {
    final host = _hosts[k % _hosts.length];
    final pti = (k % pointNum) + 1;
    final videoType = contentType == 11 ? 6 : 1;
    // 包体 userid = 受害目标 (token 仅认证); mstid = 操作者 token
    // (服务端不校验 mstid 与身份绑定, 见 round15 MOSES-1)
    final ctx = TelemetryContext(
      userId: victimUserId,
      token: op.session.token,
      clientIp: op.clientIp,
      schoolId: op.session.schoolId,
      memberProvinceCode: op.session.provinceCode ?? '',
      schoolProvinceCode: op.session.provinceCode ?? '',
      sdkVersion: _endpointConfig.sdkVersion,
      userAgent: _endpointConfig.userAgent,
      videoBizCode: AppConstants.defaultVideoBizCode,
      playerSn: AppConstants.playerSn,
    );
    try {
      return await op.telemetry.sendCollectBatchToHost(
        host: host,
        ctx: ctx,
        sessionId: op.sessionId,
        secret: op.secret,
        lessonId: lessonId,
        courseId: courseId,
        action: 2,
        stayTime: stayMs,
        beginTs: beginTs,
        pointTimeId: pti,
        pointNum: pointNum,
        uuid: op.nextUuid(),
        mediaTime: stayMs,
        speed: speed,
        videoType: videoType,
      );
    } catch (e) {
      return CollectResult(
        host: host,
        fallback: 0,
        httpStatus: 0,
        code: 0,
        msg: 'exception',
        serverTs: null,
        success: false,
        signature: '',
        reportTime: op.telemetry.clock.now(),
        error: '$e',
      );
    }
  }

  // ─── 工具 ───

  /// 可取消的秒级等待 (250ms 步进检查取消标志)
  Future<void> _sleepSeconds(int seconds) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!isCancelled() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  String _mask(String s, int keepLen) {
    if (s.length <= keepLen) return s;
    return '${s.substring(0, keepLen)}...';
  }
}

/// 快刷3 待注入课时 (轻量任务描述, 与 ReportTask 解耦避免循环依赖)
class Fast3Task {
  final String title;
  final String homeworkId;
  final String lessonId;
  final String taskId;
  final String schoolId;
  final int? contentType;
  final int duration;

  const Fast3Task({
    required this.title,
    required this.homeworkId,
    required this.lessonId,
    this.taskId = '',
    this.schoolId = '',
    this.contentType,
    this.duration = 0,
  });
}

/// 快刷3 操作者 (独立 token / BFE 会话 / uuid 序列)
class _Fast3Operator {
  final int index;
  final UserSession session;
  final String sessionId;
  final String secret;
  final String clientIp;
  final TelemetryRemoteDataSource telemetry;

  int _uuidSeq = 0;
  late final String _uuidPrefix =
      List.generate(8, (_) => _chars[_random.nextInt(_chars.length)]).join();

  static const _chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  static final Random _random = Random();

  _Fast3Operator({
    required this.index,
    required this.session,
    required this.sessionId,
    required this.secret,
    required this.clientIp,
    required this.telemetry,
  });

  String nextUuid() {
    _uuidSeq += 1;
    return 'r3_${_uuidPrefix}_${index}_$_uuidSeq';
  }
}
