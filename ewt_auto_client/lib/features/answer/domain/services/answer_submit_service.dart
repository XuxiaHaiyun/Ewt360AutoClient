/// 答案提交服务，对齐 Web answer-pc 提交逻辑：保存做题痕迹（tempSaveAnswerNew）与交卷（studentSubmitPaperAnswers）。
/// 关键约束：同一题目不允许同时传 myAnswers 与 attachmentImages；需注入 ossUploader/renderContext 主观题图片上传才生效。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../entities/image_upload_config.dart';
import '../entities/question_info.dart';
import '../../data/datasources/answer_remote_datasource.dart';
import '../../data/services/oss_upload_service.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import 'image_generation_service.dart';

/// 答案提交类型
enum SubmitType {
  /// 提交做题痕迹 (仅保存答案, 不交卷)
  /// 对齐 Web tempSaveAnswerNew
  trace,

  /// 提交答题结果 (保存答案 + 最终交卷)
  /// 对齐 Web tempSaveAnswerNew + studentSubmitPaperAnswers
  result,
}

/// 答案提交结果
class SubmitResult {
  final bool success;
  final String message;
  final int submittedCount;
  final SubmitType type;

  const SubmitResult({
    required this.success,
    required this.message,
    required this.submittedCount,
    required this.type,
  });
}

/// 答案提交服务
///
/// 对齐 Web answer-pc 页面的提交逻辑 (index.BHezKgUj.js):
/// - answerCompensation(1): 调 tempSaveAnswerNew 保存答案, 成功后调 studentSubmitPaperAnswers 交卷
/// - answerCompensation(2): 仅调 tempSaveAnswerNew 保存答案 (校对模式)
///
/// 答案对象结构 (对齐 Web answerListTask):
/// - 客观题: {id, cateId, myAnswers: ["A"], questionNo, totalSeconds}
/// - 主观题: {id, cateId, attachmentImages: [], questionNo, totalSeconds}
/// - 子题: {id, parentId, cateId, attachmentImages: [], questionNo, totalSeconds}
class AnswerSubmitService {
  final AnswerRemoteDataSource _remote;
  final OssUploadService? ossUploader;

  /// 用于图片生成的 [BuildContext] (能拿到 Overlay 的 context)。
  ///
  /// 主观题"根据答案/解析生成图片"方案需要通过 [Overlay] 在屏幕外渲染
  /// [flutter_html] 的 [Html] widget, 才能正确渲染图片与公式 (与展示页一致)。
  /// 为 null 时回退到固定图片 (assets/images/onlyhead.png)。
  BuildContext? renderContext;

  /// 日志流 (对齐 AnswerService.logStream 模式)
  ///
  /// 提交过程中输出实时日志 (如"正在上传图片"/"保存做题痕迹成功"等),
  /// 供 [TaskProgressDialog] 订阅显示。
  final _logController = StreamController<ProgressLogEvent>.broadcast();
  bool _cancelled = false;
  bool _disposed = false;

  AnswerSubmitService(
    this._remote, {
    this.ossUploader,
    this.renderContext,
  });

  /// 日志流 (供 TaskProgressDialog 订阅)
  Stream<ProgressLogEvent> get logStream => _logController.stream;

  /// 取消提交 (由调用方在用户点击"停止"时调用)
  void cancel() {
    _cancelled = true;
    _log('用户停止提交', level: LogLevel.warning);
  }

  /// 释放资源 (关闭日志流)
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _logController.close();
  }

  void _log(String msg, {LogLevel level = LogLevel.info}) {
    if (_disposed || _logController.isClosed) return;
    _logController.add(ProgressLogEvent(msg, level: level));
  }

  /// 提交答案
  ///
  /// [result] 课程答案结果 (含 paperId/reportId/bizCode 等)
  /// [type] 提交类型 (trace=仅保存, result=保存+交卷)
  /// [selectedQuestions] 选中的题目列表 (已按题型过滤)
  /// [totalSeconds] 答题总时长 (秒), 默认 600
  /// [imageUploadConfig] 图片上传类题型的上传方案配置,
  ///   为主观题 (subjective=true) 设置 attachmentImages
  ///   (调用方需同时注入 [ossUploader] 才能生效, 否则忽略)
  Future<SubmitResult> submit({
    required CourseAnswerResult result,
    required SubmitType type,
    required List<QuestionInfo> selectedQuestions,
    double totalSeconds = 600,
    ImageUploadConfig? imageUploadConfig,
  }) async {
    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '答题结果';
    _log('开始提交$typeLabel: ${result.courseTitle} '
        '(${selectedQuestions.length} 题, paperId=${result.paperId})');

    if (result.reportId.isEmpty) {
      final msg = '缺少 reportId, 无法提交 (该课程可能未通过 bizCode=204/201 获取)';
      _log('  ✗ $msg', level: LogLevel.error);
      return SubmitResult(
        success: false,
        message: msg,
        submittedCount: 0,
        type: type,
      );
    }

    // 1. 构造 questionList (展开子题)
    //    如启用图片上传, 为主观题生成图片并上传, 设置 attachmentImages

    // 1.0 检测部分题目是否缺少 id, 若是则用 API 重新获取题目列表补全
    //     (对齐用户要求: "部分缺少 id 使用 api 重新获取题目列表")
    //     重新获取走 getAnswerPaper (bizCode=204), 返回含 id/题干/答案的完整列表;
    //     按已选题型过滤以保留用户的题型选择, 过滤为空则用全部刷新题目。
    var effectiveQuestions = selectedQuestions;
    if (_hasMissingId(selectedQuestions)) {
      _log('  检测到部分题目缺少 id, 重新获取题目列表...');
      final refreshed = await _refreshQuestionList(result);
      if (refreshed != null && refreshed.isNotEmpty) {
        final selectedTypes = _selectedTypeSet(selectedQuestions);
        final filtered = selectedTypes.isEmpty
            ? refreshed
            : refreshed
                .where((q) => selectedTypes.contains(q.questionType))
                .toList();
        effectiveQuestions = filtered.isNotEmpty ? filtered : refreshed;
        final withId = _countWithId(effectiveQuestions);
        _log('  重新获取 ${refreshed.length} 题, 当前可提交 $withId 题');
      } else {
        _log('  重新获取题目列表失败, 按原列表提交', level: LogLevel.warning);
      }
    }

    if (_cancelled) {
      _log('  已取消', level: LogLevel.warning);
      return SubmitResult(
        success: false,
        message: '已取消提交',
        submittedCount: 0,
        type: type,
      );
    }
    _log('  构造题目列表 (含图片上传)...');
    final questionList = await _buildQuestionListWithImages(
      effectiveQuestions,
      imageUploadConfig,
      subjectName: result.subjectName,
    );
    if (questionList.isEmpty) {
      _log('  ✗ 没有可提交的题目 (所有题目缺少 id)', level: LogLevel.error);
      return SubmitResult(
        success: false,
        message: '没有可提交的题目 (所有题目缺少 id)',
        submittedCount: 0,
        type: type,
      );
    }
    _log('  题目列表: ${questionList.length} 题');

    // 提交时使用的 bizCode:
    // reportId 方案 (bizCode=201) 是越权查询方案, 提交时应转为浏览器原生方式 204
    // (201 的 reportId 已被 submitPaper 标记为"已提交", 直接用会报错)
    final submitBizCode = result.bizCode == '201' ? '204' : result.bizCode;
    // 是否是越权查询方案 (bizCode=201):
    // 该方案获取答案时调用过 submitPaper, 当前 reportId 已被服务端标记为"已提交",
    // 因此保存前必须先刷新 reportId (创建新答题报告) 才能保存成功。
    // 真实页面场景 (bizCode=204/205) 必须使用原 reportId 保存,
    // 刷新会保存到全新报告, 页面刷新后看不到进度。
    final isReportIdVia = result.bizCode == '201';
    // homeworkId:
    // - bizCode=205 (真实作业页面): 必须传真实 homeworkId, 保存才能关联到作业报告,
    //   否则刷新页面看不到保存的进度
    // - bizCode=204 (direct) / 201 (越权): 对齐 Web 默认不传 (或传 '0')
    final realHomeworkId = result.homeworkId.isNotEmpty
        ? result.homeworkId
        : '';
    final homeworkId = (submitBizCode == '205' && realHomeworkId.isNotEmpty)
        ? realHomeworkId
        : '0';

    // 2. 调用 tempSaveAnswerNew 保存做题痕迹
    //    如果返回"试卷已提交"错误, 重新获取 reportId (bizCode=204, isRepeat=1) 并重试
    //    最多尝试 3 次 (1 次原始 + 2 次刷新重试), 每次刷新都获取全新 reportId
    //
    //    仅在越权方案 (bizCode=201) 时主动刷新 reportId:
    //    该方案获取答案时调用了 submitPaper, 当前 reportId 已被标记为"已提交",
    //    直接使用原 reportId 保存必然返回"试卷已提交"错误。
    //    真实页面场景 (204/205) 不主动刷新, 使用原 reportId 保存,
    //    确保刷新页面后能看到保存的进度。
    String reportId = result.reportId;
    if (isReportIdVia) {
      final freshReportId = await _refreshReportId(
        result.paperId,
        submitBizCode,
      );
      if (freshReportId.isNotEmpty) {
        if (reportId.isNotEmpty && freshReportId != reportId) {
          _log('  主动获取新 reportId: $freshReportId (原 $reportId 可能已提交)');
        }
        reportId = freshReportId;
      }
    }

    // 205 真实作业卷: 提交前必须模拟 answer-pc 打开页面的跳转获取真实 reportId。
    // 地址栏的 reportId 是 answer-pc 内部调 report(bizCode=205, homeworkId=真实值)
    // 后追加的; 获取答案链 (越权查询) 的 reportId 是独立报告, 直接用于提交
    // 会导致保存到错误报告 (错误提交/刷新页面看不到进度), 且该报告可能已被
    // 查询链的 submitPaper 标记"已提交"。实测 report(205, 真实 homeworkId)
    // 返回的 reportId 与跳转后地址栏完全一致。
    // 获取失败时保留原 reportId 交由"试卷已提交"重试逻辑兜底。
    if (submitBizCode == '205' && realHomeworkId.isNotEmpty) {
      final realRid = await _refreshReportId(
        result.paperId,
        '205',
        homeworkId: realHomeworkId,
      );
      if (realRid.isNotEmpty) {
        if (realRid != reportId) {
          _log('  使用真实答题页 reportId: $realRid (原 $reportId 为查询链报告)');
        }
        reportId = realRid;
      } else {
        _log('  获取真实 reportId 失败, 保留原 reportId 重试',
            level: LogLevel.warning);
      }
    }
    bool saved = false;
    String lastError = '';
    for (int attempt = 0; attempt < 3; attempt++) {
      if (_cancelled) break;
      try {
        _log('  保存做题痕迹 (尝试 ${attempt + 1}/3, reportId=$reportId)...');
        final saveResp = await _remote.tempSaveAnswerNew(
          paperId: result.paperId,
          reportId: reportId,
          bizCode: submitBizCode,
          platform: result.platform,
          assignPoints: result.assignPoints,
          questionList: questionList,
          // bizCode=205 (真实作业页面) 必须传真实 homeworkId,
          // 保存才能关联到作业报告, 否则刷新页面看不到保存的进度
          homeworkId: homeworkId,
        );

        final saveSuccess = saveResp['success'] == true;
        final saveCode = saveResp['data'] is Map
            ? (saveResp['data']['code']?.toString() ?? '')
            : '';
        if (saveSuccess || saveCode == '200') {
          saved = true;
          _log('  ✓ 保存成功', level: LogLevel.success);
          break; // 保存成功
        }

        final msg = saveResp['message']?.toString() ??
            (saveResp['data'] is Map
                ? saveResp['data']['msg']?.toString() ?? '未知错误'
                : '未知错误');
        lastError = msg;
        _log('  ✗ 保存失败: $msg', level: LogLevel.warning);

        // 如果是"试卷已提交"错误, 重新获取 reportId 并重试
        // (每次尝试都刷新, 不仅仅是第一次)
        if (_isPaperSubmittedError(msg)) {
          _log('  刷新 reportId...', level: LogLevel.info);
          final newReportId = await _refreshReportId(
            result.paperId,
            submitBizCode,
            // 205 卷刷新必须带真实 homeworkId (模拟页面跳转),
            // 否则返回查询链报告, 提交仍会失败
            homeworkId: realHomeworkId,
          );
          if (newReportId.isNotEmpty) {
            reportId = newReportId;
            _log('  获取新 reportId: $reportId');
            // 即使 newReportId 与当前相同也重试 (服务端可能暂时性错误)
            if (attempt < 2) continue;
          } else if (attempt < 2) {
            _log('  刷新 reportId 失败, 仍重试一次', level: LogLevel.warning);
            // 无法获取新 reportId, 但仍重试一次 (可能是暂时性错误)
            continue;
          }
          // 最终失败: reportId 刷新失败且已用完重试次数
          return SubmitResult(
            success: false,
            message: '保存做题痕迹失败: 试卷已提交且无法获取新 reportId '
                '(原始错误: $msg)',
            submittedCount: 0,
            type: type,
          );
        }

        // 非"已提交"错误, 直接返回失败
        return SubmitResult(
          success: false,
          message: '保存做题痕迹失败: $msg',
          submittedCount: 0,
          type: type,
        );
      } catch (e) {
        lastError = '$e';
        _log('  ✗ 保存异常: $e', level: LogLevel.error);
        return SubmitResult(
          success: false,
          message: '保存做题痕迹异常: $e',
          submittedCount: 0,
          type: type,
        );
      }
    }

    // 循环结束但未保存成功: 返回失败 (避免误报成功)
    if (!saved) {
      if (_cancelled) {
        return SubmitResult(
          success: false,
          message: '已取消提交',
          submittedCount: 0,
          type: type,
        );
      }
      return SubmitResult(
        success: false,
        message: '保存做题痕迹失败: $lastError',
        submittedCount: 0,
        type: type,
      );
    }

    // 3. 如果仅保存做题痕迹, 到此结束
    if (type == SubmitType.trace) {
      _log('✓ $typeLabel提交完成 (${questionList.length} 题)',
          level: LogLevel.success);
      return SubmitResult(
        success: true,
        message: '已保存做题痕迹 (${questionList.length} 题)',
        submittedCount: questionList.length,
        type: type,
      );
    }

    if (_cancelled) {
      _log('  已取消 (做题痕迹已保存, 未交卷)', level: LogLevel.warning);
      return SubmitResult(
        success: false,
        message: '已取消提交 (做题痕迹已保存)',
        submittedCount: questionList.length,
        type: type,
      );
    }

    // 4. 提交答题结果: 调用 studentSubmitPaperAnswers 最终交卷
    _log('  交卷中 (homeworkId=$homeworkId)...');
    try {
      final submitResp = await _remote.studentSubmitPaperAnswers(
        paperId: result.paperId,
        reportId: reportId,
        bizCode: submitBizCode,
        homeworkId: homeworkId,
        platform: result.platform,
        paperPackageId: result.paperPackageId,
        totalSeconds: totalSeconds,
      );

      final submitSuccess = submitResp['success'] == true;
      final submitCode = submitResp['data'] is Map
          ? (submitResp['data']['code']?.toString() ?? '')
          : '';
      if (submitSuccess || submitCode == '200') {
        _log('  ✓ 交卷成功', level: LogLevel.success);
        _log('✓ $typeLabel提交完成 (${questionList.length} 题)',
            level: LogLevel.success);
        return SubmitResult(
          success: true,
          message: '交卷成功 (${questionList.length} 题)',
          submittedCount: questionList.length,
          type: type,
        );
      }

      final msg = submitResp['message']?.toString() ??
          (submitResp['data'] is Map
              ? submitResp['data']['msg']?.toString() ?? '未知错误'
              : '未知错误');
      _log('  ✗ 交卷失败: $msg (做题痕迹已保存)', level: LogLevel.warning);
      return SubmitResult(
        success: false,
        message: '交卷失败: $msg (做题痕迹已保存)',
        submittedCount: questionList.length,
        type: type,
      );
    } catch (e) {
      _log('  ✗ 交卷异常: $e (做题痕迹已保存)', level: LogLevel.error);
      return SubmitResult(
        success: false,
        message: '交卷异常: $e (做题痕迹已保存)',
        submittedCount: questionList.length,
        type: type,
      );
    }
  }

  /// 判断是否为"试卷已提交"错误
  static bool _isPaperSubmittedError(String msg) {
    return msg.contains('已提交') || msg.contains('请刷新');
  }

  /// 重新获取 reportId (bizCode=204, isRepeat=1 创建新答题报告; 205 模拟页面跳转)
  ///
  /// reportId 方案 (bizCode=201) 获取答案时会调用 submitPaper 将试卷标记为"已提交",
  /// 之后 tempSaveAnswerNew 会返回"试卷已提交, 请刷新页面"错误。
  /// 此方法通过 getAnswerReport(bizCode=204, reportId=0&isRepeat=1) 获取新的
  /// 未提交 reportId, 用于重试提交。
  ///
  /// bizCode=205 时模拟 answer-pc 跳转: getAnswerReport(bizCode=205,
  /// homeworkId=真实值, reportId=0&isRepeat=0&extId=homeworkId),
  /// 返回真实答题页面使用的 reportId (越权查询报告不可用于提交)。
  ///
  /// 返回空字符串表示获取失败 (调用方应记录日志以便诊断)。
  Future<String> _refreshReportId(
    String paperId,
    String bizCode, {
    String homeworkId = '0',
  }) async {
    try {
      final targetBizCode = bizCode == '205' ? '205' : '204';
      final reportResult = await _remote.getAnswerReport(
        paperId: paperId,
        bizCode: targetBizCode,
        homeworkId: homeworkId,
      );
      final success = reportResult['success'] == true;
      final data = reportResult['data'];
      if (success && data is Map<String, dynamic>) {
        final rid = (data['reportId'] ?? '').toString();
        if (rid.isNotEmpty && rid != '0') return rid;
      }
      // 获取失败: 返回空字符串, 调用方会重试或返回错误
      return '';
    } catch (e) {
      // 异常: 返回空字符串, 调用方会重试或返回错误
      return '';
    }
  }

  /// 构造 questionList, 并为主观题生成/上传图片
  ///
  /// 流程:
  /// 1. 调用 [_buildQuestionList] 构造基础 questionList (展开子题, 去重)
  /// 2. 若 [imageUploadConfig] 非空且 [ossUploader] 已注入:
  ///    - 为每个主观题 (subjective=true) 生成图片 (固定/根据答案)
  ///    - 上传到 OSS, 获取可访问 URL
  ///    - 将 URL 列表写入对应条目的 attachmentImages 字段
  /// 3. 未配置或上传失败的题目 attachmentImages 保持为空数组 (不影响其他题目)
  Future<List<Map<String, dynamic>>> _buildQuestionListWithImages(
    List<QuestionInfo> questions,
    ImageUploadConfig? imageUploadConfig, {
    String subjectName = '',
  }) async {
    final questionList = _buildQuestionList(questions);

    // 未启用图片上传, 直接返回基础列表
    // (使用局部变量捕获 ossUploader, 确保 null 检查后类型提升生效)
    final uploader = ossUploader;
    if (imageUploadConfig == null || uploader == null) {
      return questionList;
    }

    // 收集需要生成图片的题目 (主观题)
    final subjectiveQuestions = <QuestionInfo>[];
    for (final q in questions) {
      if (q.childQuestions.isNotEmpty) {
        for (final child in q.childQuestions) {
          if (child.id.isNotEmpty && child.subjective) {
            subjectiveQuestions.add(child);
          }
        }
      } else if (q.id.isNotEmpty && q.subjective) {
        subjectiveQuestions.add(q);
      }
    }

    if (subjectiveQuestions.isEmpty) return questionList;

    // 按 mode 分支: custom 上传用户选择的图片并按策略分配;
    //              fixed/generate 调 generateForQuestions 生成后上传
    // urlMap: questionId → 该题的 attachmentImages URL 列表 (支持多张)
    final urlMap = <String, List<String>>{};
    if (imageUploadConfig.mode == ImageUploadMode.custom) {
      await _uploadCustomImages(
        imageUploadConfig: imageUploadConfig,
        subjectiveQuestions: subjectiveQuestions,
        uploader: uploader,
        urlMap: urlMap,
      );
    } else {
      _log('    为主观题生成图片 (${subjectiveQuestions.length} 题)...');
      // 注入 BuildContext, 让 generate 模式能用 Overlay + flutter_html
      // 渲染 HTML 与图片/公式 (与答案展示页一致)
      ImageGenerationService.instance.renderContext = renderContext;
      // 批量生成图片字节
      final imageBytesMap = await ImageGenerationService.instance
          .generateForQuestions(
        config: imageUploadConfig,
        questions: subjectiveQuestions,
        subjectName: subjectName,
      );

      // 上传到 OSS 并收集 URL (每题一张)
      int uploadOk = 0, uploadFail = 0;
      for (final entry in imageBytesMap.entries) {
        try {
          final url = await uploader.uploadImage(
            entry.value,
            'answer_${entry.key}.png',
          );
          urlMap[entry.key] = <String>[url];
          uploadOk++;
        } catch (e) {
          uploadFail++;
          _log('    图片上传失败 (id=${entry.key}): $e', level: LogLevel.warning);
          // 单题上传失败不影响其他题目
        }
      }
      _log('    图片上传完成: 成功 $uploadOk, 失败 $uploadFail');
    }

    // 将 URL 列表写入 questionList 中对应条目的 attachmentImages
    // 重要: 服务端不允许同时传 myAnswers 和 attachmentImages (返回 7771202),
    // 因此上传成功后必须移除 myAnswers 字段, 只保留 attachmentImages。
    if (urlMap.isNotEmpty) {
      for (final entry in questionList) {
        final id = entry['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final urls = urlMap[id];
        if (urls != null && urls.isNotEmpty) {
          entry.remove('myAnswers');
          entry['attachmentImages'] = List<String>.from(urls);
        }
      }
    }

    return questionList;
  }

  /// 上传用户选择的自定义图片并按 [CustomImageAssignment] 策略分配
  ///
  /// 两种策略:
  /// - [CustomImageAssignment.allShared]: 上传图片池, 每题都用全部图片 (多张)
  /// - [CustomImageAssignment.manual]: 按 manualImageBytes 为每题上传其专属图片 (可多张)
  ///
  /// 成功的 URL 列表写入 [urlMap] (key = questionId, value = 该题的 URL 列表)。
  Future<void> _uploadCustomImages({
    required ImageUploadConfig imageUploadConfig,
    required List<QuestionInfo> subjectiveQuestions,
    required OssUploadService uploader,
    required Map<String, List<String>> urlMap,
  }) async {
    switch (imageUploadConfig.customAssignment) {
      case CustomImageAssignment.allShared:
        await _assignAllShared(
          imageUploadConfig, subjectiveQuestions, uploader, urlMap);
      case CustomImageAssignment.manual:
        await _assignManual(imageUploadConfig, uploader, urlMap);
    }
  }

  /// 全部题相同: 每道主观题都用全部选中的图片 (多张)
  Future<void> _assignAllShared(
    ImageUploadConfig cfg,
    List<QuestionInfo> subjectiveQuestions,
    OssUploadService uploader,
    Map<String, List<String>> urlMap,
  ) async {
    if (cfg.customImageBytes.isEmpty) {
      _log('    自定义图片为空, 跳过图片上传', level: LogLevel.warning);
      return;
    }
    _log('    上传自定义图片 (${cfg.customImageBytes.length} 张, 全部题相同)...');
    final urls = await _uploadImagesToList(
      cfg.customImageBytes, cfg.customImageNames, uploader, 'custom');
    if (urls.isEmpty) return;
    for (final q in subjectiveQuestions) {
      if (q.id.isEmpty) continue;
      urlMap[q.id] = List<String>.from(urls);
    }
    _log('    已将 ${urls.length} 张图片共享给 ${subjectiveQuestions.length} 道主观题');
  }

  /// 手动分配: 按 manualImageBytes 为每道主观题上传其专属图片 (可多张)
  Future<void> _assignManual(
    ImageUploadConfig cfg,
    OssUploadService uploader,
    Map<String, List<String>> urlMap,
  ) async {
    final manual = cfg.manualImageBytes;
    if (manual.isEmpty) {
      _log('    手动分配为空, 跳过图片上传', level: LogLevel.warning);
      return;
    }
    _log('    手动分配: 为 ${manual.length} 道主观题上传专属图片...');
    final names = cfg.manualImageNames;
    int totalOk = 0, totalFail = 0;
    for (final entry in manual.entries) {
      if (_cancelled) break;
      final qid = entry.key;
      final imgs = entry.value;
      if (imgs.isEmpty) continue;
      final imgNames = names[qid] ?? const <String>[];
      final urls = await _uploadImagesToList(
        imgs, imgNames, uploader, 'manual_$qid');
      if (urls.isNotEmpty) {
        urlMap[qid] = urls;
        totalOk += urls.length;
      } else {
        totalFail += imgs.length;
      }
    }
    _log('    手动分配完成: 上传成功 $totalOk, 失败 $totalFail');
  }

  /// 上传一组图片字节到 OSS, 返回成功上传的 URL 列表
  ///
  /// [names] 为对应文件名 (用于 OSS 命名), 长度不足时用 `${fallbackPrefix}_$i.png`。
  Future<List<String>> _uploadImagesToList(
    List<Uint8List> bytesList,
    List<String> names,
    OssUploadService uploader,
    String fallbackPrefix,
  ) async {
    final urls = <String>[];
    int ok = 0, fail = 0;
    for (int i = 0; i < bytesList.length; i++) {
      if (_cancelled) break;
      final name = (i < names.length && names[i].isNotEmpty)
          ? names[i]
          : '${fallbackPrefix}_$i.png';
      try {
        final url = await uploader.uploadImage(bytesList[i], name);
        urls.add(url);
        ok++;
      } catch (e) {
        fail++;
        _log('    图片上传失败 ($name): $e', level: LogLevel.warning);
      }
    }
    _log('    图片上传完成: 成功 $ok, 失败 $fail');
    return urls;
  }

  /// 从 QuestionInfo 列表构造提交用的 questionList
  ///
  /// 对齐 Web answerCompensation 中的逻辑:
  /// - 展开子题 (childQuestions 中的每个子题作为独立条目)
  /// - 客观题: myAnswers = rightAnswerRaw (正确答案作为作答)
  /// - 主观题: attachmentImages = [] (无图片作答)
  /// - 按 id 去重 (对齐 Web 的 dedup 逻辑)
  static List<Map<String, dynamic>> _buildQuestionList(
    List<QuestionInfo> questions,
  ) {
    final result = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    for (final q in questions) {
      if (q.id.isEmpty) continue;

      // 分组题: 展开子题
      if (q.childQuestions.isNotEmpty) {
        for (final child in q.childQuestions) {
          if (child.id.isEmpty || seenIds.contains(child.id)) continue;
          seenIds.add(child.id);
          result.add(_buildAnswerEntry(child));
        }
      } else if (!seenIds.contains(q.id)) {
        seenIds.add(q.id);
        result.add(_buildAnswerEntry(q));
      }
    }

    return result;
  }

  /// 构造单个答案条目
  ///
  /// 对齐 Web answerCompensation 中 questionList 的构造:
  /// - 每项为 {id, cateId, questionNo, totalSeconds, myAnswers|attachmentImages}
  ///
  /// 重要: 服务端按题型校验答案字段 (返回 7771202):
  /// - 客观题 (subjective=false): 必须用 `myAnswers`, 不能用 `attachmentImages`
  /// - 主观题 (subjective=true): 必须用 `attachmentImages`, 不能用 `myAnswers`
  /// 主观题的图片 URL 由 [_buildQuestionListWithImages] 在上传成功后
  /// 通过替换 `attachmentImages` 数组内容来注入。
  static Map<String, dynamic> _buildAnswerEntry(QuestionInfo q) {
    final entry = <String, dynamic>{
      'id': q.id,
      'cateId': q.cate,
      'questionNo': 0,
      'totalSeconds': 0,
    };

    if (q.subjective) {
      // 主观题: 必须用 attachmentImages (无图片时为空数组)
      // 图片 URL 由 _buildQuestionListWithImages 在上传成功后替换
      entry['attachmentImages'] = <String>[];
    } else {
      // 客观题: 必须用 myAnswers
      entry['myAnswers'] = q.rightAnswerRaw.isNotEmpty
          ? q.rightAnswerRaw
          : <String>[];
    }

    return entry;
  }

  // ─── 缺少 id 时重新获取题目列表 ───

  /// 检测题目列表中是否有任何题目 (含子题) 缺少 id
  ///
  /// 分组题 (有 childQuestions) 检查每个子题; 普通题检查自身。
  static bool _hasMissingId(List<QuestionInfo> questions) {
    for (final q in questions) {
      if (q.childQuestions.isNotEmpty) {
        for (final c in q.childQuestions) {
          if (c.id.isEmpty) return true;
        }
      } else if (q.id.isEmpty) {
        return true;
      }
    }
    return false;
  }

  /// 统计题目列表中含 id 的可提交数量 (含子题展开)
  static int _countWithId(List<QuestionInfo> questions) {
    int count = 0;
    for (final q in questions) {
      if (q.childQuestions.isNotEmpty) {
        for (final c in q.childQuestions) {
          if (c.id.isNotEmpty) count++;
        }
      } else if (q.id.isNotEmpty) {
        count++;
      }
    }
    return count;
  }

  /// 收集已选题目中出现的题型集合 (用于刷新后按题型过滤)
  static Set<String> _selectedTypeSet(List<QuestionInfo> questions) {
    final types = <String>{};
    for (final q in questions) {
      if (q.questionType.isNotEmpty) types.add(q.questionType);
    }
    return types;
  }

  /// 重新获取题目列表 (含 id/题干/答案/子题)
  ///
  /// 调用 [AnswerRemoteDataSource.getAnswerPaper] (bizCode=204),
  /// 该接口返回试卷完整题目列表, 每题含 id/questionNoShow/cate/subjective/
  /// rightAnswer/childQuestions, 可直接用于提交。
  ///
  /// 失败返回 null (调用方回退到原列表, 仅跳过缺 id 的题目)。
  Future<List<QuestionInfo>?> _refreshQuestionList(
    CourseAnswerResult result,
  ) async {
    try {
      final resp = await _remote.getAnswerPaper(
        paperId: result.paperId,
        reportId: result.reportId,
        bizCode: '204',
      );
      if (resp['success'] != true) {
        _log('  重新获取失败: ${resp['message'] ?? '未知错误'}',
            level: LogLevel.warning);
        return null;
      }
      final data = resp['data'];
      if (data is! Map<String, dynamic>) return null;
      final rawList = (data['questions'] as List<dynamic>?) ?? [];
      final list = <QuestionInfo>[];
      for (final q in rawList) {
        if (q is Map<String, dynamic>) {
          list.add(QuestionInfo.fromJson(q));
        }
      }
      return list;
    } catch (e) {
      _log('  重新获取题目列表异常: $e', level: LogLevel.warning);
      return null;
    }
  }
}