/// 并发控制工具单元测试 (离线)
library;

import 'package:ewt_auto_client/core/utils/concurrency.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runWithConcurrency', () {
    test('空任务列表返回空结果', () async {
      final r = await runWithConcurrency<int>([]);
      expect(r, isEmpty);
    });

    test('结果按原顺序返回', () async {
      final r = await runWithConcurrency([
        () async => 1,
        () async => 2,
        () async => 3,
      ], concurrency: 2);
      expect(r, [1, 2, 3]);
    });

    test('并发度被限制 (同时运行数不超过 concurrency)', () async {
      var running = 0;
      var maxRunning = 0;
      final r = await runWithConcurrency([
        for (var i = 0; i < 8; i++)
          () async {
            running++;
            if (running > maxRunning) maxRunning = running;
            await Future.delayed(const Duration(milliseconds: 20));
            running--;
            return i;
          },
      ], concurrency: 3);
      expect(r.length, 8);
      expect(maxRunning, lessThanOrEqualTo(3));
      expect(maxRunning, greaterThan(1)); // 确有并发, 而非完全串行
    });

    test('concurrency 超过任务数时按任务数执行', () async {
      final r = await runWithConcurrency([
        () async => 'a',
        () async => 'b',
      ], concurrency: 99);
      expect(r, ['a', 'b']);
    });

    test('concurrency <= 0 时降级为串行', () async {
      var running = 0;
      var maxRunning = 0;
      await runWithConcurrency([
        for (var i = 0; i < 4; i++)
          () async {
            running++;
            if (running > maxRunning) maxRunning = running;
            await Future.delayed(const Duration(milliseconds: 5));
            running--;
          },
      ], concurrency: 0);
      expect(maxRunning, 1);
    });

    test('任务抛错向上传播', () async {
      expect(
        () => runWithConcurrency([
          () async => 1,
          () async => throw StateError('boom'),
        ]),
        throwsA(isA<StateError>()),
      );
    });
  });
}
