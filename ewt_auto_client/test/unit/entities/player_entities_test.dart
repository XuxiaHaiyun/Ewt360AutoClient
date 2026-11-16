/// 播放器领域实体单元测试 (离线)
///
/// 覆盖 [VideoSession] / [SeriousCheckConfig] / [TelemetryContext] /
/// [InteractiveConfig] / [PlaybackProgress] 的纯逻辑。
library;

import 'package:ewt_auto_client/features/player/domain/entities/serious_check_config.dart';
import 'package:ewt_auto_client/features/player/domain/entities/telemetry_context.dart';
import 'package:ewt_auto_client/features/player/domain/entities/video_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoSession', () {
    VideoSession buildSession({int duration = 600, int playedTime = 0}) =>
        VideoSession(
          homeworkId: 'hw',
          lessonId: 'ls',
          videoId: 'vd',
          sessionId: 'sess',
          secret: 'sec',
          duration: duration,
          playedTime: playedTime,
        );

    test('needsFocusCheck: 视频 > 180s 需要专注检查', () {
      expect(buildSession(duration: 600).needsFocusCheck, isTrue);
      expect(buildSession(duration: 180).needsFocusCheck, isFalse);
      expect(buildSession(duration: 100).needsFocusCheck, isFalse);
    });

    test('progress: 已播/总时长 归一化到 [0,1]', () {
      expect(buildSession(duration: 600, playedTime: 300).progress, 0.5);
      expect(buildSession(duration: 600, playedTime: 0).progress, 0.0);
    });

    test('progress 越界钳制 (playedTime > duration)', () {
      expect(buildSession(duration: 100, playedTime: 500).progress, 1.0);
      expect(buildSession(duration: 100, playedTime: -10).progress, 0.0);
    });

    test('duration=0 时 progress 为 0 (避免除零)', () {
      expect(buildSession(duration: 0, playedTime: 10).progress, 0.0);
    });

    test('默认字段: taskId 空, contentType=1, isCompleted=false', () {
      final s = buildSession();
      expect(s.taskId, '');
      expect(s.contentType, 1);
      expect(s.isCompleted, isFalse);
      expect(s.interactiveConfigs, isEmpty);
    });
  });

  group('InteractiveConfig', () {
    test('默认 timePoint=0', () {
      const cfg = InteractiveConfig(id: 'p1');
      expect(cfg.timePoint, 0);
      expect(cfg.id, 'p1');
    });
  });

  group('SeriousCheckConfig', () {
    test('默认降级 (level=1), 安全 fallback', () {
      const cfg = SeriousCheckConfig();
      expect(cfg.level, 1);
      expect(cfg.isDowngrade, isTrue);
      expect(cfg.isEnabled, isFalse);
    });

    test('level=0 正常检测', () {
      const cfg = SeriousCheckConfig(level: 0);
      expect(cfg.isDowngrade, isFalse);
      expect(cfg.isEnabled, isTrue);
    });

    test('fromJson: int 与字符串 level 均解析', () {
      expect(SeriousCheckConfig.fromJson({'level': 0}).level, 0);
      expect(SeriousCheckConfig.fromJson({'level': '2'}).level, 2);
    });

    test('fromJson: 缺失/非法 level 回退默认 1', () {
      expect(SeriousCheckConfig.fromJson({}).level, 1);
      expect(SeriousCheckConfig.fromJson({'level': 'abc'}).level, 1);
    });

    test('fromJson: needLog 解析', () {
      expect(SeriousCheckConfig.fromJson({'needLog': 1}).needLog, 1);
      expect(SeriousCheckConfig.fromJson({'needLog': '0'}).needLog, 0);
      expect(SeriousCheckConfig.fromJson({}).needLog, 0);
    });

    test('toString 输出调试信息', () {
      const cfg = SeriousCheckConfig(level: 0, tips: 'hi');
      expect(cfg.toString(), contains('level=0'));
      expect(cfg.toString(), contains('tips=hi'));
    });
  });

  group('TelemetryContext', () {
    test('构造完整字段', () {
      const ctx = TelemetryContext(
        userId: '10001',
        token: 'tok',
        clientIp: '1.2.3.4',
        schoolId: '10000',
        memberProvinceCode: '44',
        schoolProvinceCode: '44',
        sdkVersion: '3.0.37',
        userAgent: 'UA',
        videoBizCode: '1013',
        playerSn: 'ewt_web_video_detail',
      );
      expect(ctx.userId, '10001');
      expect(ctx.sdkVersion, '3.0.37');
      expect(ctx.videoBizCode, '1013');
      expect(ctx.playerSn, 'ewt_web_video_detail');
    });
  });

  group('PlaybackProgress', () {
    test('fraction 归一化', () {
      const p = PlaybackProgress(
        state: PlaybackState.playing,
        playedSeconds: 300,
        totalSeconds: 600,
      );
      expect(p.fraction, 0.5);
    });

    test('totalSeconds=0 时 fraction 为 0', () {
      const p = PlaybackProgress(
        state: PlaybackState.initializing,
        playedSeconds: 0,
        totalSeconds: 0,
      );
      expect(p.fraction, 0.0);
    });

    test('状态可穷尽列举 (编译期保证)', () {
      const states = [
        PlaybackState.initializing,
        PlaybackState.starting,
        PlaybackState.playing,
        PlaybackState.focusChecking,
        PlaybackState.interactive,
        PlaybackState.finishing,
        PlaybackState.completed,
        PlaybackState.failed,
        PlaybackState.cancelled,
      ];
      expect(states, hasLength(9));
      expect(states.toSet(), hasLength(9), reason: '状态枚举无重复');
    });
  });
}
