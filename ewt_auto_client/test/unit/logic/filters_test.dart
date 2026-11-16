/// 课程过滤逻辑单元测试 (离线, 不依赖账号/网络)
///
/// 覆盖两个"课程列表 → 任务列表"的纯过滤函数:
///   - [AnswerService.applyFilter] (静态): 答案获取前的课程过滤
///   - [ProgressReportService.filterCourses] (实例): 进度上报前的任务提取
///
/// 从原端到端测试文件中提取纯函数部分, 使离线可跑。
library;

import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/answer/domain/entities/answer_filter_config.dart';
import 'package:ewt_auto_client/features/answer/presentation/services/answer_service.dart';
import 'package:ewt_auto_client/features/player/domain/entities/report_config.dart';
import 'package:ewt_auto_client/features/player/presentation/services/progress_report_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnswerService.applyFilter', () {
    test('filterNoHomework=true 过滤 taskId 为空课程', () {
      // 2026-08-24 后"有作业"判定升级: taskId 非空之外还需有题目或导学案。
      final mockCourses = <Map<String, dynamic>>[
        {'title': 'A', 'taskId': '', 'lessonId': '1'},
        {'title': 'B', 'taskId': '100', 'lessonId': '2', 'itemCount': 5},
        {'title': 'C', 'taskId': '0', 'lessonId': '3'},
        {'title': 'D', 'taskId': '200', 'lessonId': '4', 'studyGuideId': '9'},
      ];
      const cfg = AnswerFilterConfig(filterNoHomework: true);
      final filtered = AnswerService.applyFilter(mockCourses, cfg);
      expect(filtered.length, 2);
      expect(filtered.first['title'], 'B');
      expect(filtered.last['title'], 'D');
    });

    test('filterCompleted=true 过滤 homeworkFinishStatus==1 课程', () {
      final mockCourses = <Map<String, dynamic>>[
        {'title': 'A', 'taskId': '1', 'itemCount': 1, 'homeworkFinishStatus': 1},
        {'title': 'B', 'taskId': '2', 'itemCount': 1, 'homeworkFinishStatus': 0},
        {'title': 'C', 'taskId': '3', 'itemCount': 1},
      ];
      // 显式关闭默认开启的 filterNoHomework, 单测完成态过滤
      const cfg = AnswerFilterConfig(
        filterNoHomework: false,
        filterCompleted: true,
      );
      final filtered = AnswerService.applyFilter(mockCourses, cfg);
      expect(filtered.length, 2);
    });

    test('selectedTypes 含 null 不过滤类型', () {
      final mockCourses = <Map<String, dynamic>>[
        {'title': 'A', 'taskId': '1', 'itemCount': 1, 'contentType': 1},
        {'title': 'B', 'taskId': '2', 'itemCount': 1, 'contentType': 2},
        {'title': 'C', 'taskId': '3', 'itemCount': 1, 'contentType': 11},
      ];
      // filterNoHomework 默认 true, 会先按作业判定过滤
      const cfg = AnswerFilterConfig(); // selectedTypes=[null]
      final filtered = AnswerService.applyFilter(mockCourses, cfg);
      expect(filtered.length, 3);
    });

    test('selectedTypes 不含 null 过滤指定类型', () {
      final mockCourses = <Map<String, dynamic>>[
        {'title': 'A', 'taskId': '1', 'itemCount': 1, 'contentType': 1},
        {'title': 'B', 'taskId': '2', 'itemCount': 1, 'contentType': 2},
        {'title': 'C', 'taskId': '3', 'itemCount': 1, 'contentType': 11},
      ];
      const cfg = AnswerFilterConfig(selectedTypes: [1, 11]);
      final filtered = AnswerService.applyFilter(mockCourses, cfg);
      expect(filtered.length, 2);
      expect(filtered.any((c) => c['contentType'] == 2), isFalse);
    });

    test('selectedSubjects 非空按学科过滤', () {
      final mockCourses = <Map<String, dynamic>>[
        {'title': 'A', 'taskId': '1', 'itemCount': 1, 'subjectName': '语文'},
        {'title': 'B', 'taskId': '2', 'itemCount': 1, 'subjectName': '数学'},
        {'title': 'C', 'taskId': '3', 'itemCount': 1, 'subjectName': '英语'},
      ];
      // 关闭默认开启的 filterNoHomework, 单测学科过滤
      const cfg = AnswerFilterConfig(
        filterNoHomework: false,
        selectedSubjects: ['数学', '英语'],
      );
      final filtered = AnswerService.applyFilter(mockCourses, cfg);
      expect(filtered.length, 2);
    });
  });

  group('ProgressReportService.filterCourses', () {
    late ProgressReportService service;

    setUp(() {
      final endpointConfig = EndpointConfig.defaults();
      final client = DioClient(endpointConfig: endpointConfig);
      service = ProgressReportService(
        client: client,
        endpointConfig: endpointConfig,
      );
    });

    tearDown(() => service.dispose());

    test('filterCompleted=true 跳过 taskStatus==30', () {
      final mock = <Map<String, dynamic>>[
        {'title': 'A', 'lessonId': '1', 'taskStatus': 30, 'contentType': 1},
        {'title': 'B', 'lessonId': '2', 'taskStatus': 10, 'contentType': 1},
        {'title': 'C', 'lessonId': '3', 'taskStatus': 20, 'contentType': 1},
      ];
      const cfg = ReportConfig(
        filterCompleted: true,
        selectedTypes: [null],
      );
      final tasks = service.filterCourses(mock, cfg, '');
      expect(tasks.length, 2);
      expect(tasks.any((t) => t.title == 'A'), isFalse);
    });

    test('selectedTypes=[1,3,11] 过滤课程类型', () {
      final mock = <Map<String, dynamic>>[
        {'title': 'A', 'lessonId': '1', 'contentType': 1},
        {'title': 'B', 'lessonId': '2', 'contentType': 2},
        {'title': 'C', 'lessonId': '3', 'contentType': 3},
        {'title': 'D', 'lessonId': '4', 'contentType': 11},
        {'title': 'E', 'lessonId': '5', 'contentType': 4},
      ];
      const cfg = ReportConfig(selectedSubjects: []);
      final tasks = service.filterCourses(mock, cfg, '');
      expect(tasks.length, 3);
    });

    test('selectedSubjects 非空按学科过滤 (subjectName 主判断)', () {
      final mock = <Map<String, dynamic>>[
        {'title': 'A', 'lessonId': '1', 'subjectName': '语文', 'contentType': 1},
        {'title': 'B', 'lessonId': '2', 'subjectName': '数学', 'contentType': 1},
        {'title': 'C', 'lessonId': '3', 'subjectName': '英语', 'contentType': 1},
      ];
      const cfg = ReportConfig(
        selectedSubjects: ['数学'],
        selectedTypes: [null],
      );
      final tasks = service.filterCourses(mock, cfg, '');
      expect(tasks.length, 1);
      expect(tasks.first.title, 'B');
    });

    test('selectedSubjects 空不过滤学科', () {
      final mock = <Map<String, dynamic>>[
        {'title': 'A', 'lessonId': '1', 'subjectName': '语文', 'contentType': 1},
        {'title': 'B', 'lessonId': '2', 'subjectName': '数学', 'contentType': 1},
      ];
      const cfg = ReportConfig(
        selectedSubjects: [],
        selectedTypes: [null],
      );
      final tasks = service.filterCourses(mock, cfg, '');
      expect(tasks.length, 2);
    });

    test('subjectId 反查学科 (subject 为数字 ID)', () {
      final mock = <Map<String, dynamic>>[
        {'title': 'A', 'lessonId': '1', 'subject': 1, 'contentType': 1},
        {'title': 'B', 'lessonId': '2', 'subject': 2, 'contentType': 1},
      ];
      const cfg = ReportConfig(
        selectedSubjects: ['数学'],
        selectedTypes: [null],
      );
      final tasks = service.filterCourses(mock, cfg, '');
      expect(tasks.length, 1);
      expect(tasks.first.title, 'B', reason: 'subject=2 反查为数学');
    });

    test('无 lessonId 的课程被剔除', () {
      final mock = <Map<String, dynamic>>[
        {'title': 'A', 'contentType': 1}, // 无 lessonId
        {'title': 'B', 'lessonId': '2', 'contentType': 1},
      ];
      const cfg = ReportConfig(selectedTypes: [null]);
      final tasks = service.filterCourses(mock, cfg, '');
      expect(tasks.length, 1);
      expect(tasks.first.title, 'B');
    });

    test('ReportTask 字段映射 (title/lessonId/taskId/contentType/duration)', () {
      final mock = [
        {
          'title': '高一数学',
          'lessonId': 'ls1',
          'taskId': 'tk1',
          'videoId': 'vd1',
          'contentType': 1,
          'duration': '300', // 字符串时长
        },
      ];
      const cfg = ReportConfig(selectedTypes: [null]);
      final tasks = service.filterCourses(mock, cfg, 'hw_001',
          schoolId: '10000');
      final t = tasks.single;
      expect(t.title, '高一数学');
      expect(t.lessonId, 'ls1');
      expect(t.taskId, 'tk1');
      expect(t.videoId, 'vd1');
      expect(t.contentType, 1);
      expect(t.duration, 300);
      expect(t.homeworkId, 'hw_001');
      expect(t.schoolId, '10000');
    });
  });
}
