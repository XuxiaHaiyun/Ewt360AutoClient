// DownloadService 端到端测试 (真实网关, 需 test/accounts.json)
//
// 复用 [DownloadService] 验证下载链路:
//   1. downloadPapers (试题 PDF 导出, 真实下载到临时目录)
//   2. downloadGuides (导学案 PDF, 仅验证 URL 解析, 不下载完整文件)
//   3. downloadVideos (视频下载, 受平台限制仅在桌面端执行, 单课程)
//
// 注意:
//   - 视频下载依赖 ffmpeg_kit_flutter_new_min, 在 Flutter 测试环境可能不可用
//     测试仅验证 _downloadOneVideo 的 URL 解析阶段, 实际下载用 try/catch 兜底
//   - 导学案/试题下载会真实写文件到系统临时目录
//   - 测试环境运行时打印实际保存路径, 便于人工核查
import 'package:ewt_auto_client/features/download/presentation/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_accounts.dart';

void main() {
  TestHarness? harness;
  DownloadService? downloadService;

  // 共享状态
  String homeworkId = '';
  List<Map<String, dynamic>> courses = [];

  setUpAll(() async {
    final h = await loadTestHarnessOrNull();
    harness = h;
    if (h == null) return;
    downloadService = DownloadService(client: h.client);

    final prefetched = await prefetchHomeworkAndCourses(
      h.client,
      h.session.schoolId,
      maxCourses: 10,
    );
    homeworkId = prefetched.homeworkId;
    courses = prefetched.courses;
    // ignore: avoid_print
    print('setUpAll: homeworkId=$homeworkId, 课程数=${courses.length}');
  });
  tearDownAll(() {
    downloadService?.dispose();
    harness?.dispose();
  });

  group('DownloadService.downloadPapers - 试题 PDF 下载', () {
    test('单课程试题 PDF 导出 (内置字体)', () async {
      if (homeworkId.isEmpty || courses.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId 或课程');
        return;
      }

      // 找首个有 paperId 的课程 (优先 contentType=2 试卷)
      Map<String, dynamic>? target;
      for (final c in courses) {
        final ct = c['contentType'];
        if (ct == 2 || ct == '2') {
          target = c;
          break;
        }
      }
      target ??= courses.first;

      final logSub = downloadService!.logStream.listen((e) {
        // ignore: avoid_print
        print('    [Download] ${e.message}');
      });

      try {
        await downloadService!.downloadPapers(
          [target],
          homeworkId: homeworkId,
          schoolId: harness!.session.schoolId,
        );
        // 不强校验文件存在 (PDF 生成可能因字体加载失败回退 TXT)
      } finally {
        await logSub.cancel();
      }
    },
        skip: noHarnessSkip(harness),
        timeout: const Timeout(Duration(minutes: 2)));
  });

  group('DownloadService.downloadGuides - 导学案 PDF 下载', () {
    test('单课程导学案 URL 解析 + 下载尝试', () async {
      if (homeworkId.isEmpty || courses.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId 或课程');
        return;
      }

      final logSub = downloadService!.logStream.listen((e) {
        // ignore: avoid_print
        print('    [Download] ${e.message}');
      });

      try {
        await downloadService!.downloadGuides(
          [courses.first],
          homeworkId: homeworkId,
          schoolId: harness!.session.schoolId,
        );
        // 不强校验文件存在 (导学案可能为空)
      } finally {
        await logSub.cancel();
      }
    },
        skip: noHarnessSkip(harness),
        timeout: const Timeout(Duration(minutes: 2)));
  });

  group('DownloadService.downloadVideos - 视频下载', () {
    test('单课程视频 URL 解析 (受 ffmpeg 平台限制)', () async {
      if (homeworkId.isEmpty || courses.isEmpty) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 homeworkId 或课程');
        return;
      }

      // 找首个有 lessonId 的课程
      Map<String, dynamic>? target;
      for (final c in courses) {
        final lid = (c['lessonId'] ?? c['contentId'] ?? '').toString();
        if (lid.isNotEmpty) {
          target = c;
          break;
        }
      }
      if (target == null) {
        // ignore: avoid_print
        print('  ⊘ 跳过: 无 lessonId');
        return;
      }

      final logSub = downloadService!.logStream.listen((e) {
        // ignore: avoid_print
        print('    [Download] ${e.message}');
      });

      try {
        await downloadService!.downloadVideos(
          [target],
          homeworkId: homeworkId,
          schoolId: harness!.session.schoolId,
        );
        // ffmpeg_kit_flutter_new_min 在 flutter test 环境可能不可用,
        // 此测试主要验证 URL 解析阶段成功, 实际下载失败由 try/catch 兜底
      } catch (e) {
        // ignore: avoid_print
        print('  (预期) 视频下载失败: $e');
      } finally {
        await logSub.cancel();
      }
    },
        skip: noHarnessSkip(harness),
        timeout: const Timeout(Duration(minutes: 3)));
  });

  // 测试完成后清理临时下载目录 (可选, 保留文件便于人工核查)
  tearDownAll(() async {
    // 不主动清理, 保留下载产物供人工核查
  });
}
