/// 并发控制工具
///
/// 提供有限并发度的异步任务调度, 防止 `Future.wait` 全量并发导致
/// 资源耗尽 / 服务端限流 (对齐 progress_report_service 的 worker 池模式)。
library;

/// 以最多 [concurrency] 个并发执行 [tasks] 中的异步任务, 返回按原顺序的结果。
///
/// - 任务懒启动: 前 [concurrency] 个立即开始, 完成的 worker 立即接管下一个任务
/// - 任一任务抛错会向上传播 (由调用方决定是否隔离)
/// - [concurrency] <= 0 时视为 1 (至少串行执行)
Future<List<T>> runWithConcurrency<T>(
  List<Future<T> Function()> tasks, {
  int concurrency = 5,
}) async {
  if (tasks.isEmpty) return const [];
  final n = concurrency.clamp(1, tasks.length);
  final results = List<T?>.filled(tasks.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next;
      if (i >= tasks.length) return;
      next++;
      results[i] = await tasks[i]();
    }
  }

  await Future.wait([for (var w = 0; w < n; w++) worker()]);
  return results.cast<T>();
}
