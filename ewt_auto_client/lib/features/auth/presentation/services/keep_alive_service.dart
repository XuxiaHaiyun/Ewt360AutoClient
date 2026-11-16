/// 账号保活服务：多账号并行、每账号独立 DioClient，定时（默认 3s）轮询 getUser 防止 token 过期。
/// 每轮并发上限 5 防限流；持续运行直到用户手动停止，状态与日志经流式接口供 UI 展示。
library;

import 'dart:async';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/config/endpoint_config.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/utils/concurrency.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../domain/entities/user_session.dart';

/// 账号保活服务
///
/// 用于批量执行任务中"保持账号活跃"项: 多账号并行, 每个账号独立 Dio 实例
/// (不共享全局 DioClient, 避免互相覆盖 token), 死循环定时调用 getUser 接口
/// 查询用户信息, 防止 token 过期。除非用户手动停止。
///
/// 对齐 Python 批量任务的设计 (但 Python 未实现 keep_alive, 此为 Flutter 新增):
/// - 每账号独立 client (对应 Python `_execute_for_account` 中 `EWTClient()` 新建)
/// - 并行执行 (对应 Python `ThreadPoolExecutor`)
/// - 用户提供停止机制 (对应 Python `StoppableQThread`)
class KeepAliveService {
  /// 保活间隔, 默认 3 秒
  ///
  /// 用户要求 3 秒间隔, 远小于 token 有效期, 足够保活。
  static const Duration defaultInterval = Duration(seconds: 3);

  /// 保活账号列表
  final List<UserSession> _accounts;

  /// 保活间隔
  final Duration interval;

  /// 每账号一个独立的 DioClient (避免共享 token)
  final Map<String, DioClient> _clients = {};

  /// 日志流
  final _logController = StreamController<ProgressLogEvent>.broadcast();

  /// 每账号的实时状态 (用于 UI 显示)
  final Map<String, AccountKeepAliveState> _states = {};

  /// 状态变化通知
  final _stateController = StreamController<Map<String, AccountKeepAliveState>>.broadcast();

  /// 停止标志
  bool _stopped = false;
  bool _disposed = false;

  /// 每轮最大并发查询账号数 (防大量账号同时发包触发限流)
  static const int _parallelLimit = 5;

  /// 当前轮次
  int _round = 0;

  KeepAliveService({
    required List<UserSession> accounts,
    required EndpointConfig endpointConfig,
    this.interval = defaultInterval,
  })  : _accounts = accounts {
    // 为每个账号创建独立的 DioClient (支持每账号独立代理)
    for (final acc in _accounts) {
      final client = DioClient(endpointConfig: endpointConfig, proxy: acc.proxy);
      client.token = acc.token;
      _clients[acc.token] = client;
      _states[acc.token] = AccountKeepAliveState(
        account: acc,
        status: KeepAliveStatus.idle,
        lastCheck: null,
        lastSuccess: null,
        failCount: 0,
        message: '等待开始',
      );
    }
  }

  Stream<ProgressLogEvent> get logStream => _logController.stream;
  Stream<Map<String, AccountKeepAliveState>> get stateStream => _stateController.stream;
  Map<String, AccountKeepAliveState> get states => Map.unmodifiable(_states);
  bool get isRunning => !_stopped && !_disposed;
  int get round => _round;

  void _log(String msg, {LogLevel level = LogLevel.info}) {
    if (_disposed || _logController.isClosed) return;
    _logController.add(ProgressLogEvent(msg, level: level));
  }

  void _updateState(String token, AccountKeepAliveState newState) {
    _states[token] = newState;
    if (!_stateController.isClosed) {
      _stateController.add(Map.unmodifiable(_states));
    }
  }

  /// 启动保活循环 (直到 stop() 被调用)
  Future<void> start() async {
    _stopped = false;
    _log('开始保活: ${_accounts.length} 个账号, 间隔 ${interval.inSeconds} 秒');

    while (!_stopped && !_disposed) {
      _round++;
      _log('── 第 $_round 轮保活开始 ──');
      _updateAllStatus(KeepAliveStatus.checking, '第 $_round 轮查询中...');

      // 并行查询所有账号 (有限并发, 防大量账号同时发包触发限流)
      await runWithConcurrency(
        [for (final acc in _accounts) () => _checkOne(acc)],
        concurrency: _parallelLimit,
      );

      if (_stopped || _disposed) break;

      final okCount = _states.values.where((s) => s.status == KeepAliveStatus.alive).length;
      final failCount = _states.values.where((s) => s.status == KeepAliveStatus.dead).length;
      _log('第 $_round 轮完成: 存活 $okCount, 失效 $failCount',
          level: failCount > 0 ? LogLevel.warning : LogLevel.success);

      // 等待下一轮 (可中断) — 仅更新提示文字, 保留各账号实际 alive/dead 状态
      for (final token in _states.keys) {
        final old = _states[token]!;
        _states[token] = AccountKeepAliveState(
          account: old.account,
          status: old.status,
          lastCheck: old.lastCheck,
          lastSuccess: old.lastSuccess,
          failCount: old.failCount,
          message: '等待 ${interval.inSeconds} 秒后下一轮...',
        );
      }
      if (!_stateController.isClosed) {
        _stateController.add(Map.unmodifiable(_states));
      }
      try {
        await Future.delayed(interval);
      } catch (_) {
        break;
      }
    }

    _log('保活已停止 (共执行 $_round 轮)', level: LogLevel.warning);
  }

  /// 查询单个账号 (使用独立 DioClient, 调用 getUser 接口)
  Future<void> _checkOne(UserSession acc) async {
    if (_stopped || _disposed) return;

    final client = _clients[acc.token];
    if (client == null) {
      _updateState(acc.token, AccountKeepAliveState(
        account: acc,
        status: KeepAliveStatus.dead,
        lastCheck: DateTime.now(),
        lastSuccess: _states[acc.token]?.lastSuccess,
        failCount: (_states[acc.token]?.failCount ?? 0) + 1,
        message: '未找到 client',
      ));
      return;
    }

    final displayName = acc.displayName ?? acc.account ?? acc.userId;
    _updateState(acc.token, AccountKeepAliveState(
      account: acc,
      status: KeepAliveStatus.checking,
      lastCheck: DateTime.now(),
      lastSuccess: _states[acc.token]?.lastSuccess,
      failCount: _states[acc.token]?.failCount ?? 0,
      message: '查询中...',
    ));

    try {
      final resp = await client.get<Map<String, dynamic>>(
        ApiConstants.userInfoUrl,
      );

      if (_stopped || _disposed) return;

      if (resp.isSuccess) {
        _updateState(acc.token, AccountKeepAliveState(
          account: acc,
          status: KeepAliveStatus.alive,
          lastCheck: DateTime.now(),
          lastSuccess: DateTime.now(),
          failCount: 0,
          message: '[$displayName] 存活 ✓',
        ));
        _log('  ✓ [$displayName] 存活 (第 $_round 轮)', level: LogLevel.success);
      } else {
        final failCount = (_states[acc.token]?.failCount ?? 0) + 1;
        _updateState(acc.token, AccountKeepAliveState(
          account: acc,
          status: KeepAliveStatus.dead,
          lastCheck: DateTime.now(),
          lastSuccess: _states[acc.token]?.lastSuccess,
          failCount: failCount,
          message: '[$displayName] 失效: ${resp.msg}',
        ));
        _log('  ✗ [$displayName] 失效: ${resp.msg} (第 $_round 轮)',
            level: LogLevel.error);
      }
    } catch (e) {
      if (_stopped || _disposed) return;
      final failCount = (_states[acc.token]?.failCount ?? 0) + 1;
      _updateState(acc.token, AccountKeepAliveState(
        account: acc,
        status: KeepAliveStatus.dead,
        lastCheck: DateTime.now(),
        lastSuccess: _states[acc.token]?.lastSuccess,
        failCount: failCount,
        message: '[$displayName] 异常: $e',
      ));
      _log('  ✗ [$displayName] 异常: $e (第 $_round 轮)',
          level: LogLevel.error);
    }
  }

  void _updateAllStatus(KeepAliveStatus status, String message) {
    for (final token in _states.keys) {
      final old = _states[token]!;
      _states[token] = AccountKeepAliveState(
        account: old.account,
        status: status,
        lastCheck: old.lastCheck,
        lastSuccess: old.lastSuccess,
        failCount: old.failCount,
        message: message,
      );
    }
    if (!_stateController.isClosed) {
      _stateController.add(Map.unmodifiable(_states));
    }
  }

  /// 停止保活循环
  void stop() {
    _stopped = true;
    _log('收到停止信号, 将在当前操作完成后退出', level: LogLevel.warning);
  }

  /// 释放资源
  void dispose() {
    _stopped = true;
    _disposed = true;
    _clients.clear();
    if (!_logController.isClosed) _logController.close();
    if (!_stateController.isClosed) _stateController.close();
  }
}

/// 账号保活状态
enum KeepAliveStatus { idle, checking, alive, dead }

/// 单个账号的保活状态
class AccountKeepAliveState {
  final UserSession account;
  final KeepAliveStatus status;
  final DateTime? lastCheck;
  final DateTime? lastSuccess;
  final int failCount;
  final String message;

  AccountKeepAliveState({
    required this.account,
    required this.status,
    required this.lastCheck,
    required this.lastSuccess,
    required this.failCount,
    required this.message,
  });
}
