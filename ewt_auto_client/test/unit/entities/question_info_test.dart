/// QuestionInfo 实体单元测试 (离线)
///
/// 覆盖 [QuestionInfo.fromJson] 的解析逻辑:
///   - 答案格式化 (选择题合并 / 主观题多答案序号 / 空数组)
///   - 图片 URL 归一化 (http→https, // 协议相对, / 站内相对)
///   - 选项提取 (字符串型 / 对象型 / choice 兜底)
///   - 子题递归 / 提交字段提取
library;

import 'package:ewt_auto_client/features/answer/domain/entities/question_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QuestionInfo.fromJson - 答案格式化', () {
    test('选择题 (全 A-Z): 合并为 "A, B, C"', () {
      final q = QuestionInfo.fromJson({
        'rightAnswer': ['A', 'B', 'C'],
      });
      expect(q.answer, 'A, B, C');
    });

    test('多选题答案不受限', () {
      final q = QuestionInfo.fromJson({
        'rightAnswer': ['A', 'B', 'C', 'D'],
      });
      expect(q.answer, 'A, B, C, D');
    });

    test('主观题多答案: 每项加序号 + <br> 分隔', () {
      final q = QuestionInfo.fromJson({
        'rightAnswer': ['白日依山尽', '黄河入海流'],
      });
      expect(q.answer, '1、白日依山尽<br>2、黄河入海流');
    });

    test('空数组 rightAnswer → 空字符串 (答案未解锁)', () {
      final q = QuestionInfo.fromJson({'rightAnswer': <dynamic>[]});
      expect(q.answer, '');
    });

    test('字符串 "[]" 防御: 视为空答案', () {
      final q = QuestionInfo.fromJson({'rightAnswer': '[]'});
      expect(q.answer, '');
    });

    test('单答案主观题: 直接返回 (不加序号)', () {
      final q = QuestionInfo.fromJson({'rightAnswer': ['sin x']});
      expect(q.answer, 'sin x');
    });

    test('字符串型 rightAnswer 直接使用', () {
      final q = QuestionInfo.fromJson({'rightAnswer': 'x = 1'});
      expect(q.answer, 'x = 1');
    });
  });

  group('QuestionInfo.fromJson - 图片 URL 归一化', () {
    test('http:// 转 https://', () {
      final q = QuestionInfo.fromJson({
        'analyse': '<img src="http://file.ewt360.com/a.png">',
      });
      expect(q.analysis, contains('src="https://file.ewt360.com/a.png"'));
    });

    test('协议相对 // 转 https://', () {
      final q = QuestionInfo.fromJson({
        'analyse': '<img src="//file.ewt360.com/b.png">',
      });
      expect(q.analysis, contains('src="https://file.ewt360.com/b.png"'));
    });

    test('站内相对 /path 补全 web.ewt360.com', () {
      final q = QuestionInfo.fromJson({
        'questionContent': '<img src="/c.png">',
      });
      expect(
        q.questionContent,
        contains('src="https://web.ewt360.com/c.png"'),
      );
    });

    test('已是 https 的 URL 不处理', () {
      final q = QuestionInfo.fromJson({
        'analyse': '<img src="https://file.ewt360.com/d.png">',
      });
      expect(q.analysis, contains('src="https://file.ewt360.com/d.png"'));
    });
  });

  group('QuestionInfo.fromJson - 选项提取', () {
    test('字符串型选项直接使用', () {
      final q = QuestionInfo.fromJson({
        'options': ['A. 选项一', 'B. 选项二'],
      });
      expect(q.options, ['A. 选项一', 'B. 选项二']);
    });

    test('对象型选项 (choice + option) 拼接', () {
      final q = QuestionInfo.fromJson({
        'options': [
          {'choice': 'A', 'option': '甲'},
          {'choice': 'B', 'option': '乙'},
        ],
      });
      expect(q.options, ['A. 甲', 'B. 乙']);
    });

    test('choice 缺失时用 A/B/C 序号兜底', () {
      final q = QuestionInfo.fromJson({
        'options': [
          {'option': 'one'},
          {'option': 'two'},
        ],
      });
      expect(q.options, ['A. one', 'B. two']);
    });

    test('空选项忽略', () {
      final q = QuestionInfo.fromJson({
        'options': ['', '  '],
      });
      expect(q.options, isEmpty);
    });
  });

  group('QuestionInfo.fromJson - 结构与提交字段', () {
    test('子题递归解析 (number 按索引)', () {
      final q = QuestionInfo.fromJson({
        'childQuestions': [
          {'rightAnswer': ['A']},
          {'rightAnswer': ['B']},
        ],
      });
      expect(q.childQuestions.length, 2);
      expect(q.childQuestions[0].number, '1');
      expect(q.childQuestions[1].number, '2');
    });

    test('知识标签拼接 (knowledges.title)', () {
      final q = QuestionInfo.fromJson({
        'knowledges': [
          {'title': '函数'},
          {'title': '导数'},
          {'title': ''},
        ],
      });
      expect(q.knowledge, '函数、导数');
    });

    test('题型名称优先级 subjectQuestionTypeName > questionTypeName > cateName', () {
      final q = QuestionInfo.fromJson({
        'subjectQuestionTypeName': '解答题',
        'questionTypeName': '填空题',
      });
      expect(q.questionType, '解答题');
    });

    test('提交字段: id/cate/subjective/questionNoShow/rightAnswerRaw', () {
      final q = QuestionInfo.fromJson({
        'id': 'q_9',
        'cate': 21,
        'subjective': true,
        'questionNoShow': '1-2',
        'questionSort': '3',
        'parentQuestionId': 'p_1',
        'rightAnswer': ['A', 'B', ''],
      });
      expect(q.id, 'q_9');
      expect(q.cate, 21);
      expect(q.subjective, isTrue);
      expect(q.questionNoShow, '1-2');
      expect(q.questionSort, 3); // 字符串转 int
      expect(q.parentId, 'p_1');
      expect(q.rightAnswerRaw, ['A', 'B']);
    });

    test('subjective 字符串 "true" 兼容', () {
      final q = QuestionInfo.fromJson({'subjective': 'true'});
      expect(q.subjective, isTrue);
    });

    test('难度字段 degreeRangeDesc', () {
      final q = QuestionInfo.fromJson({'degreeRangeDesc': '中等'});
      expect(q.difficulty, '中等');
    });
  });
}
