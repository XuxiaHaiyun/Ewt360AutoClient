/// 自动签到状态管理与 Riverpod Provider。
/// [CheckinNotifier.runRace] 用当前登录账号发送一次签到请求，按 code == '200' 判定成功（竞态探测已废弃）。
library;

import 'dart:async';

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/checkin_remote_datasource.dart';

/// 单次签到尝试结果
class CheckinAttemptResult {
  /// 是否命中 (code == '200', 对齐 Python 竞态判定)
  final bool success;
  /// 服务端 code (或 'ERR' 表示请求抛异常)
  final String code;
  /// 服务端 msg / 异常信息
  final String msg;

  const CheckinAttemptResult({
    required this.success,
    required this.code,
    required this.msg,
  });
}

/// 自动签到结果
class CheckinRaceOutcome {
  /// 发起次数 (固定 1, 仅发一次签到请求)
  final int total;
  /// 成功次数 (code == '200')
  final int success;
  /// 单次尝试明细
  final List<CheckinAttemptResult> attempts;
  /// 顶层致命错误 (几乎不会发生, 单次失败已被 attempt 级别吞掉)
  final String? errorMessage;

  const CheckinRaceOutcome({
    required this.total,
    required this.success,
    required this.attempts,
    this.errorMessage,
  });

  String get summary => '成功 $success / $total';
}

/// 自动签到状态
class CheckinState {
  final bool loading;
  final CheckinRaceOutcome? lastOutcome;

  const CheckinState({this.loading = false, this.lastOutcome});

  CheckinState copyWith({bool? loading, CheckinRaceOutcome? lastOutcome}) =>
      CheckinState(
        loading: loading ?? this.loading,
        lastOutcome: lastOutcome ?? this.lastOutcome,
      );
}

/// 自动签到 Notifier
///
/// [runRace] 用当前登录账号 (token 由 DioClient 拦截器注入) 发送**一次**签到请求,
/// 按 code == '200' 判定成功。竞态探测已废弃 (服务端单日幂等, 多次并发无收益)。
class CheckinNotifier extends StateNotifier<CheckinState> {
  final CheckinRemoteDataSource _remote;

  CheckinNotifier(this._remote) : super(const CheckinState());

  /// 仅发送一次签到请求, 不并发、不查前后状态。
  Future<CheckinRaceOutcome> runRace() async {
    state = state.copyWith(loading: true);
    try {
      final result = await _attemptOnce();
      final outcome = CheckinRaceOutcome(
        total: 1,
        success: result.success ? 1 : 0,
        attempts: [result],
      );
      state = state.copyWith(loading: false, lastOutcome: outcome);
      return outcome;
    } catch (e) {
      final outcome = CheckinRaceOutcome(
        total: 1,
        success: 0,
        attempts: const [],
        errorMessage: e.toString(),
      );
      state = state.copyWith(loading: false, lastOutcome: outcome);
      return outcome;
    }
  }

  /// 单次签到 (异常在 attempt 级别吞掉, 不影响整体统计)
  Future<CheckinAttemptResult> _attemptOnce() async {
    try {
      final resp = await _remote.signOnce();
      return CheckinAttemptResult(
        success: resp.code == '200',
        code: resp.code,
        msg: resp.msg,
      );
    } on ApiException catch (e) {
      return CheckinAttemptResult(success: false, code: 'ERR', msg: e.message);
    } catch (e) {
      return CheckinAttemptResult(success: false, code: 'ERR', msg: e.toString());
    }
  }
}

final checkinRaceProvider =
    StateNotifierProvider<CheckinNotifier, CheckinState>((ref) {
  final remote = CheckinRemoteDataSource(getIt<DioClient>());
  return CheckinNotifier(remote);
});
