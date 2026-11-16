/// 过滤配置实体单元测试 (离线)
///
/// 覆盖作业/答案/上报三层过滤配置:
///   - [TaskFilterConfig]: 作业级筛选 (status/subject/type)
///   - [AnswerFilterConfig]: 课程级过滤 (无作业/已完成/类型/学科)
///   - [ReportConfig]: 上报过滤 + 快刷参数
///   - [DownloadConfig]: 下载配置组合
library;

import 'dart:convert';

import 'package:ewt_auto_client/features/answer/domain/entities/answer_filter_config.dart';
import 'package:ewt_auto_client/features/download/domain/entities/download_config.dart';
import 'package:ewt_auto_client/features/homework/domain/entities/task_filter_config.dart';
import 'package:ewt_auto_client/features/player/domain/entities/report_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskFilterConfig', () {
    test('默认配置: 进行中作业 (status=2), 不限学科/类型', () {
      const cfg = TaskFilterConfig.defaults();
      expect(cfg.status, 2);
      expect(cfg.subject, isNull);
      expect(cfg.type, isNull);
    });

    test('copyWith 更新字段', () {
      const cfg = TaskFilterConfig.defaults();
      final updated = cfg.copyWith(subject: () => 1, type: () => 2);
      expect(updated.subject, 1);
      expect(updated.type, 2);
      expect(updated.status, 2, reason: '未更新字段保留');
    });

    test('copyWith 支持显式清空为 null', () {
      const cfg = TaskFilterConfig(status: 1, subject: 2);
      final cleared = cfg.copyWith(status: () => null, subject: () => null);
      expect(cleared.status, isNull);
      expect(cleared.subject, isNull);
    });
  });

  group('AnswerFilterConfig', () {
    test('默认: 过滤无作业, 全部类型, 全部学科', () {
      const cfg = AnswerFilterConfig();
      expect(cfg.filterNoHomework, isTrue);
      expect(cfg.filterCompleted, isFalse);
      expect(cfg.isAllTypes, isTrue);
      expect(cfg.selectedSubjects, isEmpty);
    });

    test('shouldKeepType: 含 null 放行全部', () {
      const cfg = AnswerFilterConfig(selectedTypes: [null]);
      expect(cfg.shouldKeepType(1), isTrue);
      expect(cfg.shouldKeepType(null), isTrue);
    });

    test('shouldKeepType: 指定类型精确匹配', () {
      const cfg = AnswerFilterConfig(selectedTypes: [1, 11]);
      expect(cfg.shouldKeepType(1), isTrue);
      expect(cfg.shouldKeepType(11), isTrue);
      expect(cfg.shouldKeepType(2), isFalse);
      expect(cfg.shouldKeepType(null), isFalse);
    });

    test('shouldKeepSubject: 空列表放行全部', () {
      const cfg = AnswerFilterConfig(selectedSubjects: []);
      expect(cfg.shouldKeepSubject('语文'), isTrue);
      expect(cfg.shouldKeepSubject(null), isTrue);
    });

    test('shouldKeepSubject: 精确匹配学科名', () {
      const cfg = AnswerFilterConfig(selectedSubjects: ['数学']);
      expect(cfg.shouldKeepSubject('数学'), isTrue);
      expect(cfg.shouldKeepSubject('语文'), isFalse);
      expect(cfg.shouldKeepSubject(''), isFalse);
      expect(cfg.shouldKeepSubject(null), isFalse);
    });

    test('课程类型选项表完整 (19 项, 首项为全部)', () {
      expect(kCourseTypeOptions.length, 19);
      expect(kCourseTypeOptions.first.value, isNull);
      expect(kCourseTypeOptions.any((o) => o.value == 1 && o.label == '视频'),
          isTrue);
      expect(kCourseTypeOptions.any((o) => o.value == 2 && o.label == '试卷'),
          isTrue);
    });

    test('学科 ID 映射: 10/11/12 为完整名称', () {
      expect(kSubjectIdToName[1], '语文');
      expect(kSubjectIdToName[10], '心灵成长');
      expect(kSubjectIdToName[11], '生涯规划');
      expect(kSubjectIdToName[12], '综合素养');
      expect(kCourseSubjects, contains('心灵成长'));
    });
  });

  group('ReportConfig', () {
    test('默认值: 过滤已完成, 类型 [1,3,11], 心跳 60s', () {
      const cfg = ReportConfig();
      expect(cfg.filterCompleted, isTrue);
      expect(cfg.selectedTypes, [1, 3, 11]);
      expect(cfg.heartbeatInterval, 60);
      expect(cfg.completionThreshold, 0.8);
      expect(cfg.fastBrush, isFalse);
    });

    test('isAllTypes: 仅 selectedTypes 含 null 时为真', () {
      expect(const ReportConfig(selectedTypes: [null]).isAllTypes, isTrue);
      expect(const ReportConfig(selectedTypes: [1]).isAllTypes, isFalse);
    });

    test('shouldReportType: 全部类型放行 / 指定类型匹配', () {
      expect(
        const ReportConfig(selectedTypes: [null]).shouldReportType(99),
        isTrue,
      );
      expect(
        const ReportConfig(selectedTypes: [1, 3]).shouldReportType(3),
        isTrue,
      );
      expect(
        const ReportConfig(selectedTypes: [1, 3]).shouldReportType(2),
        isFalse,
      );
    });

    test('shouldReportSubject: 空学科/未知学科被排除 (与 Python 一致)', () {
      const cfg = ReportConfig(selectedSubjects: ['语文']);
      expect(cfg.shouldReportSubject('语文'), isTrue);
      expect(cfg.shouldReportSubject('数学'), isFalse);
      expect(cfg.shouldReportSubject(null), isFalse);
      expect(cfg.shouldReportSubject(''), isFalse);
    });

    test('快刷 burst 参数默认值', () {
      const cfg = ReportConfig();
      expect(cfg.fastBrushWafBackoff, 120);
      expect(cfg.fastBrushEventsPerRequest, 0);
    });
  });

  group('ReportConfig 序列化 (配置持久化)', () {
    test('toJson/fromJson 往返一致', () {
      const cfg = ReportConfig(
        filterCompleted: false,
        filterSeriousCheckChecked: true,
        selectedTypes: [null],
        selectedSubjects: ['语文', '数学'],
        heartbeatInterval: 30,
        speed: 2.0,
        useBackup: true,
        reportBackend: 'dlog',
        fastBrush: true,
        fastBrushMaxRounds: 3,
        fastBrushThreads: 5,
        fastBrushWafBackoff: 150,
        fastBrushEventsPerRequest: 7,
        rebrush: true,
        rebrushRounds: 5,
        rebrushExtraMinutes: 60,
        compensate: true,
        completionThreshold: 0.85,
        resumeFromServer: false,
        realProgressQuery: false,
        progressPollInterval: 30,
        parallelExecution: true,
        parallelTaskCount: 3,
      );
      final back = ReportConfig.fromJson(cfg.toJson());
      expect(back.filterCompleted, false);
      expect(back.filterSeriousCheckChecked, true);
      expect(back.selectedTypes, [null]);
      expect(back.selectedSubjects, ['语文', '数学']);
      expect(back.heartbeatInterval, 30);
      expect(back.speed, 2.0);
      expect(back.useBackup, true);
      expect(back.reportBackend, 'dlog');
      expect(back.fastBrush, true);
      expect(back.fastBrushMaxRounds, 3);
      expect(back.fastBrushThreads, 5);
      expect(back.fastBrushWafBackoff, 150);
      expect(back.fastBrushEventsPerRequest, 7);
      expect(back.rebrush, true);
      expect(back.rebrushRounds, 5);
      expect(back.rebrushExtraMinutes, 60);
      expect(back.compensate, true);
      expect(back.completionThreshold, 0.85);
      expect(back.resumeFromServer, false);
      expect(back.realProgressQuery, false);
      expect(back.progressPollInterval, 30);
      expect(back.parallelExecution, true);
      expect(back.parallelTaskCount, 3);
    });

    test('selectedTypes 含 null 序列化后保留 null', () {
      const cfg = ReportConfig(selectedTypes: [null, 1]);
      final back = ReportConfig.fromJson(cfg.toJson());
      expect(back.selectedTypes, [null, 1]);
      expect(back.isAllTypes, isTrue);
    });

    test('fromJson 空 map 回退默认值', () {
      final back = ReportConfig.fromJson({});
      expect(back.filterCompleted, isTrue);
      expect(back.filterSeriousCheckChecked, isFalse);
      expect(back.selectedTypes, [1, 3, 11]);
      expect(back.selectedSubjects, isEmpty);
      expect(back.heartbeatInterval, 60);
      expect(back.speed, 1.0);
      expect(back.completionThreshold, 0.8);
      expect(back.parallelExecution, isFalse);
      expect(back.parallelTaskCount, 2);
    });

    test('fromJson 容错: 非法数值/字符串字段回退默认', () {
      final back = ReportConfig.fromJson({
        'speed': 'not-a-number',
        'selectedTypes': 'not-a-list',
        'selectedSubjects': 123,
      });
      expect(back.speed, 1.0);
      expect(back.selectedTypes, [1, 3, 11]); // 回退默认类型
      expect(back.selectedSubjects, isEmpty);
    });

    test('JSON 可被 jsonEncode/Decode 往返 (持久化实际路径)', () {
      const cfg = ReportConfig(parallelExecution: true, parallelTaskCount: 4);
      final raw = jsonEncode(cfg.toJson());
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final back = ReportConfig.fromJson(decoded);
      expect(back.parallelExecution, isTrue);
      expect(back.parallelTaskCount, 4);
    });
  });

  group('DownloadConfig', () {
    test('默认组合 AnswerFilterConfig', () {
      const cfg = DownloadConfig();
      expect(cfg.filterConfig, const AnswerFilterConfig());
    });

    test('copyWith 更新 filterConfig', () {
      const cfg = DownloadConfig();
      const newFilter = AnswerFilterConfig(selectedTypes: [2]);
      final updated = cfg.copyWith(filterConfig: newFilter);
      expect(updated.filterConfig, newFilter);
      expect(updated.filterConfig.selectedTypes, [2]);
    });
  });
}
