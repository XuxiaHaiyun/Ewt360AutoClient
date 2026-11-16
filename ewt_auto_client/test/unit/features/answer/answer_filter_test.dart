/// 试题答案课程过滤逻辑单元测试 (离线, 自包含)
///
/// 覆盖 [AnswerService.applyFilter] 的过滤维度:
///   - filterNoHomework: 无作业 = 无题目(itemCount/questionCount 无题)
///     且无导学案(studyGuideId 为空), 如 FM/资讯/板报 (2026-08-24 实测修复)
///   - filterCompleted: 已完成 = homeworkFinishStatus / finished /
///     allFinished / taskStatus==30 任一命中
///   - selectedTypes / selectedSubjects 基础过滤
library;

import 'package:ewt_auto_client/features/answer/domain/entities/answer_filter_config.dart';
import 'package:ewt_auto_client/features/answer/presentation/services/answer_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final baseCourses = <Map<String, dynamic>>[
    // 未完成 (taskStatus 10, finished false), 视频课程带导学案 → 有作业
    {
      'title': '未完成课程',
      'taskId': '1001',
      'contentId': 'lesson-1',
      'contentType': 1,
      'subjectName': '语文',
      'studyGuideId': 'sg-1',
      'finished': false,
      'allFinished': false,
      'taskStatus': 10,
    },
    // 已完成: finished=true (pageHomeworkTasks 服务端综合判定)
    {
      'title': '已完成-finished',
      'taskId': '1002',
      'contentId': 'lesson-2',
      'contentType': 1,
      'subjectName': '数学',
      'studyGuideId': 'sg-2',
      'finished': true,
      'allFinished': true,
      'taskStatus': 30,
    },
    // 已完成: taskStatus==30 但 finished 缺失 (视频看完)
    {
      'title': '已完成-taskStatus30',
      'taskId': '1003',
      'contentId': 'lesson-3',
      'contentType': 1,
      'subjectName': '英语',
      'studyGuideId': 'sg-3',
      'taskStatus': 30,
    },
    // 已完成: homeworkFinishStatus==1 (homework 页 studyGuide 合并写入), 试卷有题
    {
      'title': '已完成-homeworkFinishStatus',
      'taskId': '1004',
      'contentId': 'lesson-4',
      'contentType': 2,
      'subjectName': '物理',
      'itemCount': 8,
      'questionCount': 8,
      'homeworkFinishStatus': 1,
    },
    // 已完成: allFinished==1 (另一种服务端字段形态)
    {
      'title': '已完成-allFinished',
      'taskId': '1005',
      'contentId': 'lesson-5',
      'contentType': 1,
      'subjectName': '化学',
      'studyGuideId': 'sg-5',
      'allFinished': 1,
    },
    // 无作业: FM 课程 (taskId 有值但无题目且无导学案)
    {
      'title': '无作业-FM',
      'taskId': 'fm-1',
      'contentId': 'fm-30983',
      'contentType': 3,
      'subjectName': '心灵成长',
      'itemCount': null,
      'questionCount': null,
      'studyGuideId': null,
    },
    // 无作业: taskId 为空
    {
      'title': '无作业-taskId空',
      'taskId': '',
      'contentId': 'lesson-7',
      'contentType': 1,
      'subjectName': '生物',
    },
  ];

  group('filterNoHomework (过滤无作业课程)', () {
    test('过滤 FM 等无题目且无导学案的课程 (taskId 有值也算无作业)', () {
      final cfg = const AnswerFilterConfig(filterNoHomework: true);
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, isNot(contains('无作业-FM')));
      expect(titles, isNot(contains('无作业-taskId空')));
    });

    test('有导学案的视频课程保留 (studyGuideId 非空)', () {
      final cfg = const AnswerFilterConfig(filterNoHomework: true);
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, contains('未完成课程'));
      expect(titles, contains('已完成-finished'));
    });

    test('有题目的试卷课程保留 (itemCount>0)', () {
      final cfg = const AnswerFilterConfig(filterNoHomework: true);
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, contains('已完成-homeworkFinishStatus'));
    });

    test('filterNoHomework=false 时 FM 课程保留', () {
      final cfg = const AnswerFilterConfig(
        filterNoHomework: false,
        filterCompleted: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, contains('无作业-FM'));
    });
  });

  group('filterCompleted (过滤已完成课程)', () {
    test('filterCompleted=false 时全部保留', () {
      final cfg = const AnswerFilterConfig(
        filterCompleted: false,
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      expect(out.length, baseCourses.length);
    });

    test('filterCompleted=true 时剔除 finished=true 的课程', () {
      final cfg = const AnswerFilterConfig(
        filterCompleted: true,
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, isNot(contains('已完成-finished')));
      expect(titles, contains('未完成课程'));
    });

    test('filterCompleted=true 时剔除 taskStatus==30 的课程', () {
      final cfg = const AnswerFilterConfig(
        filterCompleted: true,
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, isNot(contains('已完成-taskStatus30')));
    });

    test('filterCompleted=true 时剔除 homeworkFinishStatus==1 的课程', () {
      final cfg = const AnswerFilterConfig(
        filterCompleted: true,
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, isNot(contains('已完成-homeworkFinishStatus')));
    });

    test('filterCompleted=true 时剔除 allFinished==1 的课程', () {
      final cfg = const AnswerFilterConfig(
        filterCompleted: true,
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, isNot(contains('已完成-allFinished')));
    });

    test('filterCompleted=true 保留未完成课程', () {
      final cfg = const AnswerFilterConfig(
        filterCompleted: true,
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final titles = out.map((c) => c['title']).toList();
      expect(titles, contains('未完成课程'));
    });

    test('真实 pageHomeworkTasks 样本: finished=true 被剔除', () {
      final courses = <Map<String, dynamic>>[
        {
          'title': 'J从《鸿门宴》看叙事错位',
          'contentId': '117945',
          'homeworkId': 10495544,
          'subjectId': 1,
          'contentType': 1,
          'studyGuideId': 2256528993610678495,
          'finished': true,
          'allFinished': true,
          'taskId': '2302821070241195424',
          'taskStatus': 30,
          'seriousCheckResult': 2,
        },
        {
          'title': '未完成讲次',
          'contentId': '99999',
          'homeworkId': 10495544,
          'subjectId': 2,
          'contentType': 1,
          'studyGuideId': 123456,
          'finished': false,
          'allFinished': false,
          'taskId': '9999900001',
          'taskStatus': 10,
        },
      ];
      final cfg = const AnswerFilterConfig(
        filterCompleted: true,
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(courses, cfg);
      expect(out.length, 1);
      expect(out.first['title'], '未完成讲次');
    });
  });

  group('其他过滤维度', () {
    test('filterNoHomework 保留有作业课程 (taskId 非空)', () {
      final cfg = const AnswerFilterConfig(filterNoHomework: true);
      final out = AnswerService.applyFilter(baseCourses, cfg);
      expect(out.length, 5); // 5 个有作业课程, FM 与 taskId 空被剔除
    });

    test('selectedTypes 过滤 contentType', () {
      final cfg = const AnswerFilterConfig(
        selectedTypes: [2],
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final types = out.map((c) => c['contentType']).toSet();
      expect(types, {2});
    });

    test('selectedSubjects 按 subjectName 过滤', () {
      final cfg = const AnswerFilterConfig(
        selectedSubjects: ['语文', '数学'],
        filterNoHomework: false,
      );
      final out = AnswerService.applyFilter(baseCourses, cfg);
      final subjects = out.map((c) => c['subjectName']).toSet();
      expect(subjects, isNot(contains('物理')));
    });
  });
}
