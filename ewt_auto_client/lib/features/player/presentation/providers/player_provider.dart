/// 播放器任务 Riverpod 状态管理：定义 PlayerTaskState 状态族（空闲/运行/完成/失败），
/// 并由 PlayerTaskNotifier 管理 PlaybackEngine 生命周期，将进度流事件映射为 UI 状态。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';
import '../../domain/entities/video_session.dart';
import '../../domain/services/playback_engine.dart';

/// 播放器任务状态
sealed class PlayerTaskState {
  const PlayerTaskState();
}

class PlayerIdle extends PlayerTaskState {
  const PlayerIdle();
}

class PlayerRunning extends PlayerTaskState {
  final PlaybackProgress progress;
  const PlayerRunning(this.progress);
}

class PlayerCompleted extends PlayerTaskState {
  const PlayerCompleted();
}

class PlayerError extends PlayerTaskState {
  final String message;
  const PlayerError(this.message);
}

/// 播放器任务 Notifier
///
/// 管理 PlaybackEngine 的生命周期，将 Stream 事件转为状态
class PlayerTaskNotifier extends StateNotifier<PlayerTaskState> {
  PlaybackEngine? _engine;
  StreamSubscription<PlaybackProgress>? _subscription;

  PlayerTaskNotifier() : super(const PlayerIdle());

  /// 启动播放模拟
  Future<void> startPlayback(
    VideoSession session, {
    bool fastMode = false,
  }) async {
    final client = getIt<DioClient>();
    final endpointConfig = getIt<EndpointConfig>();

    final playerRemote = PlayerRemoteDataSource(client);
    final telemetryRemote = TelemetryRemoteDataSource(client);

    _engine = PlaybackEngine(
      playerRemote: playerRemote,
      telemetryRemote: telemetryRemote,
      endpointConfig: endpointConfig,
    );

    _subscription = _engine!.progressStream.listen((progress) {
      switch (progress.state) {
        case PlaybackState.completed:
          state = const PlayerCompleted();
        case PlaybackState.failed:
          state = PlayerError(progress.error ?? '播放失败');
        case PlaybackState.cancelled:
          state = const PlayerIdle();
        default:
          state = PlayerRunning(progress);
      }
    });

    try {
      await _engine!.simulatePlayback(session, fastMode: fastMode);
    } catch (e) {
      state = PlayerError('$e');
    }
  }

  /// 停止播放
  void stop() {
    _engine?.cancel();
    _subscription?.cancel();
    state = const PlayerIdle();
  }

  @override
  void dispose() {
    _engine?.dispose();
    _subscription?.cancel();
    super.dispose();
  }
}

final playerTaskProvider =
    StateNotifierProvider<PlayerTaskNotifier, PlayerTaskState>((ref) {
  return PlayerTaskNotifier();
});
