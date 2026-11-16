/// 学科常量单元测试 (离线)
library;

import 'package:ewt_auto_client/core/constants/subject_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('subjectNameMap', () {
    test('覆盖全部学科 ID 1~16', () {
      for (var id = 1; id <= 16; id++) {
        expect(subjectNameMap.containsKey(id), isTrue,
            reason: '缺少学科 $id');
      }
    });

    test('常见学科名称正确', () {
      expect(subjectNameMap[1], '语文');
      expect(subjectNameMap[2], '数学');
      expect(subjectNameMap[3], '英语');
      expect(subjectNameMap[10], '心灵成长');
      expect(subjectNameMap[12], '综合素养');
    });
  });

  group('subjectColorMap', () {
    test('覆盖全部学科 ID 1~16', () {
      for (var id = 1; id <= 16; id++) {
        expect(subjectColorMap.containsKey(id), isTrue,
            reason: '缺少学科颜色 $id');
      }
    });

    test('颜色为不透明色', () {
      for (final c in subjectColorMap.values) {
        expect(c.a, 1.0); // Color.a 为 0~1 double
      }
    });
  });
}
