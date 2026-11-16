/// 答案远程数据源，封装 answerprod 试卷/答题卡/做题痕迹提交/收藏夹/服务端试卷 PDF 等接口。
/// 关键约束：answerprod API 要求 Origin/Referer 为 web.ewt360.com，响应以 success 布尔字段判断成功。
library;

import 'dart:convert';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/network/api_helper.dart';
import '../../../../core/network/dio_client.dart';

/// 答案远程数据源
///
/// 对应 Python: core/answer.py AnswerMixin
/// 所有 answerprod API 使用 token 认证, 响应以 success 布尔字段判断成功
///
/// 关键: answerprod API 要求 Origin/Referer 为 web.ewt360.com,
/// 而非默认的 www.ewt360.com, 否则服务端拒绝请求 (越权方案失效)。
class AnswerRemoteDataSource {
  final DioClient _client;

  AnswerRemoteDataSource(this._client);

  /// 答案 API 专用 headers (对齐 HAR: Origin/Referer = web.ewt360.com)
  ///
  /// 覆盖 AuthInterceptor 默认的 www.ewt360.com, 否则 answerprod 接口
  /// 会因 Origin 校验失败而拒绝返回数据。
  static const Map<String, dynamic> _answerHeaders = {...ApiHeaders.web};

  /// answer/paper 接口专用 headers (对齐 HAR: 含 ewt-contentstyle 等)
  ///
  /// [referUrl] 为 answer-pc 页面 URL, 含 paperId/reportId/bizCode 参数。
  Map<String, dynamic> _paperHeaders(String referUrl) => {
        ..._answerHeaders,
        'ewt-contentstyle': 'CamelCase',
        'ewt-requestsource': 'web',
        'x-requested-with': 'XMLHttpRequest',
        'referurl': referUrl,
        'token': _client.token ?? '',
      };

  // ─── paperId 解析 ───

  /// 通过 queryStudentLessonStudyGuideAndPractice 获取 paperId/reportId
  ///
  /// POST /api/homeworkprod/student/homework/task/queryStudentLessonStudyGuideAndPractice
  Future<Map<String, dynamic>> getStudyGuideAndPractice({
    required String schoolId,
    required String homeworkId,
    required List<String> taskIds,
    required List<String> lessonIds,
  }) async {
    final response = await _client.post(
      '/api/homeworkprod/student/homework/task/queryStudentLessonStudyGuideAndPractice',
      data: {
        'schoolId': int.tryParse(schoolId) ?? 0,
        'homeworkId': homeworkId,
        'taskIds': taskIds,
        'lessonIdList': lessonIds,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取导学案信息失败: ${response.msg}');
    }
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is List) return {'list': data};
    return {};
  }

  // ─── 答案 API (answerprod) ───

  /// 获取答题报告 ID
  ///
  /// GET /api/answerprod/web/answer/report
  ///
  /// 支持三种越权方案 (对齐 HAR):
  /// - bizCode=201 (油猴脚本方式): URL 传 token, 无特殊 headers
  /// - bizCode=204 (浏览器原生方式): URL 传 reportId=0&isRepeat=1&timestamp,
  ///   需 ewt-contentstyle/ewt-requestsource/x-requested-with/referurl headers
  /// - bizCode=205 (真实作业/测一测卷方式): URL 传 reportId=0&isRepeat=0,
  ///   传真实 homeworkId (及 extId) 时返回 answer-pc 页面跳转后使用的真实
  ///   reportId (对齐 answer-pc 打开页面时的 report 调用); 传 '0' 时返回
  ///   越权查询报告, 仅用于获取答案, 不可用于提交做题痕迹
  ///
  /// 均返回新的 reportId, 用于后续接口调用。
  Future<Map<String, dynamic>> getAnswerReport({
    required String paperId,
    String bizCode = '201',
    String homeworkId = '0',
  }) async {
    final params = <String, dynamic>{
      'paperId': paperId,
      'platform': '1',
      'bizCode': bizCode,
    };

    Map<String, dynamic> headers = _answerHeaders;

    if (bizCode == '204') {
      // 浏览器原生方式: 添加 reportId=0&isRepeat=1&timestamp + 特殊 headers
      params['reportId'] = '0';
      params['isRepeat'] = '1';
      params['timestamp'] = DateTime.now().millisecondsSinceEpoch.toString();
      final referUrl =
          'https://web.ewt360.com/answer-pc/exam/answer?paperId=$paperId&bizCode=204&platform=1&isRepeat=1';
      headers = _paperHeaders(referUrl);
    } else {
      // 油猴脚本方式: URL 传 token
      params['token'] = _client.token ?? '';
      if (bizCode == '205' && homeworkId.isNotEmpty) {
        // 对齐 answer-pc 打开页面时的跳转调用:
        // report?paperId=...&platform=1&extId={homeworkId}&bizCode=205&
        //   reportId=0&isRepeat=0&homeworkId={homeworkId}
        // 返回的 reportId 即真实答题页面地址栏追加的 reportId,
        // 用于提交做题痕迹/交卷 (越权查询报告不可用于提交)。
        params['reportId'] = '0';
        params['isRepeat'] = '0';
        params['extId'] = homeworkId;
        params['homeworkId'] = homeworkId;
      }
    }

    final response = await _client.get(
      ApiConstants.answerReportUrl,
      queryParameters: params,
      headers: headers,
    );
    return _handleAnswerResponse(response);
  }

  /// 获取答题卡分组题目列表
  ///
  /// POST /api/answerprod/common/answer/sheet/getAnswerSheetSubGroup
  Future<Map<String, dynamic>> getAnswerSheetSubGroup({
    required String paperId,
    required String reportId,
    String homeworkId = '0',
    String bizCode = '201',
  }) async {
    final response = await _client.post(
      ApiConstants.answerSheetSubGroupUrl,
      data: {
        'paperId': paperId,
        'reportId': reportId,
        'platform': '1',
        'bizCode': bizCode,
        'homeworkId': homeworkId,
        'client': 4,
      },
      headers: _answerHeaders,
    );
    return _handleAnswerResponse(response);
  }

  /// 获取答题卡题目列表 (非题组回退接口, 需 userId)
  ///
  /// POST /api/answerprod/common/answer/answerSheetInfo
  Future<Map<String, dynamic>> getAnswerSheetInfo({
    required String paperId,
    required String reportId,
    required String userId,
    String homeworkId = '0',
    String bizCode = '201',
  }) async {
    final response = await _client.post(
      ApiConstants.answerSheetInfoUrl,
      data: {
        'paperId': paperId,
        'reportId': reportId,
        'platform': '1',
        'bizCode': bizCode,
        'userId': userId,
        'client': 1,
      },
      headers: _answerHeaders,
    );
    return _handleAnswerResponse(response);
  }

  /// 提交答题报告 (解锁答案查询)
  ///
  /// POST /api/answerprod/web/answer/submitpaper
  Future<Map<String, dynamic>> submitPaper({
    required String paperId,
    required String reportId,
    String homeworkId = '0',
    String bizCode = '201',
  }) async {
    final response = await _client.post(
      ApiConstants.submitPaperUrl,
      data: {
        'paperId': paperId,
        'reportId': reportId,
        'bizCode': bizCode,
        'platform': '1',
        'totalSeconds': 600,
        'homeworkId': homeworkId,
      },
      headers: _answerHeaders,
    );
    return _handleAnswerResponse(response);
  }

  /// 保存做题痕迹 (对齐 Web tempSaveAnswerNew)
  ///
  /// POST /api/answerprod/web/answer/submitAnswer
  /// 请求体: {paperId, platform, reportId, questionList, bizCode, assignPoints}
  /// (对齐 Web 真实请求, 不传 homeworkId)
  ///
  /// questionList 每项含 {id, cateId, myAnswers, questionNo, totalSeconds}
  /// 或 {id, cateId, attachmentImages, questionNo, totalSeconds} (主观题带图片)
  ///
  /// 重要: 服务端不允许同一题目同时传 myAnswers 和 attachmentImages (返回 7771202),
  /// 由调用方 [AnswerSubmitService._buildAnswerEntry] 保证只设置其中一个。
  ///
  /// 必须使用 _paperHeaders (含 Ewt-RequestSource/Ewt-ContentStyle/x-requested-with),
  /// 否则服务端拒绝请求 (对齐 Web vu 实例默认 headers)。
  Future<Map<String, dynamic>> tempSaveAnswerNew({
    required String paperId,
    required String reportId,
    required String bizCode,
    required String platform,
    required bool assignPoints,
    required List<Map<String, dynamic>> questionList,
    String homeworkId = '',
  }) async {
    final referUrl = 'https://web.ewt360.com/answer-pc/exam/answer?'
        'bizCode=$bizCode&isRepeat=1&paperId=$paperId'
        '&platform=1&reportId=$reportId';
    final body = <String, dynamic>{
      'paperId': paperId,
      'platform': platform,
      'reportId': reportId,
      'questionList': questionList,
      'bizCode': bizCode,
      'assignPoints': assignPoints,
    };
    // homeworkId 仅在非空时传入 (对齐 Web: 该接口默认不传 homeworkId)
    if (homeworkId.isNotEmpty) {
      body['homeworkId'] = homeworkId;
    }
    final response = await _client.post(
      ApiConstants.tempSaveAnswerNewUrl,
      data: body,
      headers: _paperHeaders(referUrl),
    );
    return _handleAnswerResponse(response);
  }

  /// 最终交卷 (对齐 Web studentSubmitPaperAnswers)
  ///
  /// POST /api/answerprod/web/answer/submitpaper
  /// 请求体: {paperPackageId, paperId, platform, reportId, totalSeconds, bizCode, homeworkId}
  ///
  /// 必须使用 _paperHeaders (含 Ewt-RequestSource/Ewt-ContentStyle/x-requested-with),
  /// 否则服务端拒绝请求 (对齐 Web vu 实例默认 headers)。
  Future<Map<String, dynamic>> studentSubmitPaperAnswers({
    required String paperId,
    required String reportId,
    required String bizCode,
    required String homeworkId,
    required String platform,
    String paperPackageId = '',
    required double totalSeconds,
  }) async {
    final referUrl = 'https://web.ewt360.com/answer-pc/exam/answer?'
        'bizCode=$bizCode&isRepeat=1&paperId=$paperId'
        '&platform=1&reportId=$reportId';
    final response = await _client.post(
      ApiConstants.submitPaperUrl,
      data: {
        'paperPackageId': paperPackageId,
        'paperId': paperId,
        'platform': platform,
        'reportId': reportId,
        'totalSeconds': totalSeconds,
        'bizCode': bizCode,
        'homeworkId': homeworkId,
      },
      headers: _paperHeaders(referUrl),
    );
    return _handleAnswerResponse(response);
  }

  /// 获取单题答案解析
  ///
  /// POST /api/answerprod/web/answer/simple/question/analysis
  Future<Map<String, dynamic>> getQuestionAnalysis({
    required String paperId,
    required String reportId,
    required String questionId,
    String bizCode = '201',
    String homeworkId = '0',
  }) async {
    final response = await _client.post(
      ApiConstants.questionAnalysisUrl,
      data: {
        'paperId': paperId,
        'reportId': reportId,
        'platform': '1',
        'questionId': questionId,
        'bizCode': bizCode,
        'homeworkId': homeworkId,
        'client': 4,
      },
      headers: _answerHeaders,
    );
    return _handleAnswerResponse(response);
  }

  /// 获取试卷完整题目列表 (含题干/选项/答案/解析)
  ///
  /// GET /api/answerprod/web/answer/paper
  /// 必须用 bizCode=204 + _paperHeaders (含 Origin/Referer/ewt-contentstyle 等),
  /// 否则服务端不返回 questionContent (对齐 HAR)。
  Future<Map<String, dynamic>> getAnswerPaper({
    required String paperId,
    String reportId = '',
    String bizCode = '204',
  }) async {
    final referUrl = 'https://web.ewt360.com/answer-pc/exam/answer?'
        'bizCode=$bizCode&isRepeat=1&paperId=$paperId'
        '&platform=1&reportId=$reportId';

    final response = await _client.get(
      ApiConstants.answerPaperUrl,
      queryParameters: {
        'paperId': paperId,
        'platform': '1',
        'reportId': reportId,
        'bizCode': bizCode,
      },
      headers: _paperHeaders(referUrl),
    );
    return _handleAnswerResponse(response);
  }

  /// 获取整卷题目 (answer-pc 正常取题入口, 一次拉全题干/选项/子题)
  ///
  /// GET /api/answerprod/web/answer/paperQuestionGroup
  /// 参数: paperId, platform=1, reportId, bizCode, userId, homeworkId
  /// 响应 data.groups[].questions: 与 answer/paper 的 questions 字段结构一致,
  /// 可直接用 [QuestionInfo.fromJson] 解析, 无需逐题 getQuestionAnalysis。
  Future<Map<String, dynamic>> getPaperQuestionGroup({
    required String paperId,
    required String reportId,
    String bizCode = '204',
    String userId = '',
    String homeworkId = '',
  }) async {
    final referUrl = 'https://web.ewt360.com/answer-pc/exam/answer?'
        'bizCode=$bizCode&paperId=$paperId'
        '&platform=1&reportId=$reportId'
        '&homeworkId=$homeworkId';
    final response = await _client.get(
      ApiConstants.paperQuestionGroupUrl,
      queryParameters: {
        'paperId': paperId,
        'platform': '1',
        'reportId': reportId,
        'bizCode': bizCode,
        'userId': userId,
        'homeworkId': homeworkId,
      },
      headers: _paperHeaders(referUrl),
    );
    return _handleAnswerResponse(response);
  }

  /// 通过 paperId 获取试卷题目列表
  ///
  /// GET /api/answerprod/common/paper/getPaperQuestionByPaperId
  Future<Map<String, dynamic>> getPaperQuestions({
    required String paperId,
  }) async {
    final response = await _client.get(
      ApiConstants.paperQuestionUrl,
      queryParameters: {
        'paperId': paperId,
        'token': _client.token ?? '',
      },
    );
    return _handleAnswerResponse(response);
  }

  /// 获取用户基本信息 (用于 answerSheetInfo 回退)
  ///
  /// GET /api/usercenter/user/baseinfo
  Future<String> getUserId() async {
    final response = await _client.get(ApiConstants.baseInfoUrl);
    if (!response.isSuccess) return '';
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data['userId']?.toString() ?? '';
    }
    return '';
  }

  // ─── 收藏夹 API (wrongquestion) ───

  static const String helloLabelName = 'hello';

  /// 获取错题收藏夹列表
  ///
  /// GET /api/wrongquestion/label/list
  Future<Map<String, dynamic>> getWrongQuestionLabels(int subjectId) async {
    final response = await _client.get(
      '/api/wrongquestion/label/list',
      queryParameters: {'subjectId': subjectId, 'questionId': 0},
    );
    return _handleAnswerResponse(response);
  }

  /// 创建错题收藏夹
  ///
  /// POST /api/wrongquestion/label/create
  Future<Map<String, dynamic>> createWrongQuestionLabel(int subjectId) async {
    final response = await _client.post(
      '/api/wrongquestion/label/create',
      data: {'label': helloLabelName, 'subjectId': subjectId},
    );
    return _handleAnswerResponse(response);
  }

  /// 添加题目到收藏夹
  ///
  /// POST /api/wrongquestion/label/updatequestion
  Future<Map<String, dynamic>> addQuestionToLabel(
    int subjectId,
    String questionId,
    List<int> labelIds,
  ) async {
    final response = await _client.post(
      '/api/wrongquestion/label/updatequestion',
      data: {
        'subjectId': subjectId,
        'questionId': questionId,
        'labelIds': labelIds,
      },
    );
    return _handleAnswerResponse(response);
  }

  /// 从收藏夹获取题目列表
  ///
  /// GET /api/answerprod/web/wrongquestion/label/getquestion (多 URL 回退)
  Future<Map<String, dynamic>> getQuestionsFromLabel(
    dynamic labelId,
    int subjectId,
  ) async {
    const endpoints = [
      '/api/answerprod/web/wrongquestion/label/getquestion',
      '/api/answerprod/web/wrongquestion/collect/label/getquestion',
      '/api/wrongquestion/label/getquestion',
    ];
    final params = {
      'labelId': labelId,
      'subjectId': subjectId,
      'offset': 0,
      'limit': 50,
    };
    for (final endpoint in endpoints) {
      try {
        final response = await _client.get(endpoint, queryParameters: params);
        final result = _handleAnswerResponse(response);
        if (result['success'] == true) return result;
      } catch (_) {}
    }
    return {'success': false, 'message': '所有收藏夹接口均失败', 'data': null};
  }

  /// 获取收藏题目详情 (含答案)
  ///
  /// GET /api/answerprod/web/wrongquestion/collect/question/info
  Future<Map<String, dynamic>> getQuestionCollectInfo(
    String questionId,
    int subjectId,
    dynamic labelId,
  ) async {
    final response = await _client.get(
      '/api/answerprod/web/wrongquestion/collect/question/info',
      queryParameters: {
        'questionId': questionId,
        'subjectId': subjectId,
        'labelId': labelId ?? -1,
      },
    );
    return _handleAnswerResponse(response);
  }

  /// 获取收藏题目解析
  ///
  /// GET /api/answerprod/web/wrongquestion/collect/question/analysis
  Future<Map<String, dynamic>> getQuestionCollectAnalysis(
    String questionId,
    int subjectId,
    dynamic labelId,
  ) async {
    final response = await _client.get(
      '/api/answerprod/web/wrongquestion/collect/question/analysis',
      queryParameters: {
        'questionId': questionId,
        'subjectId': subjectId,
        'labelId': labelId ?? -1,
      },
    );
    return _handleAnswerResponse(response);
  }

  /// 从收藏夹移除题目
  ///
  /// POST /api/wrongquestion/label/deletequestion
  Future<Map<String, dynamic>> removeQuestionFromLabel(
    int subjectId,
    String questionId,
  ) async {
    final response = await _client.post(
      '/api/wrongquestion/label/deletequestion',
      data: {'subjectId': subjectId, 'questionId': questionId},
    );
    return _handleAnswerResponse(response);
  }

  // ─── 服务端试卷 PDF 下载 ───

  /// 触发"试卷下载"开关 (对齐 Web paper/dowload/switch)
  ///
  /// GET /api/answerprod/web/paper/dowload/switch?paperId={paperId}&bizCode=204
  /// 响应: {success, code, msg, data: true}
  /// 该接口仅触发服务端记录"用户下载过试卷", 不返回 PDF URL。
  /// 真正的 PDF URL 通过 [triggerServerPaperPdf] 获取。
  ///
  /// 失败时不抛异常 (非关键步骤, 对齐 Web: 即使 switch 失败仍可继续 print/async)。
  Future<bool> triggerPaperDownloadSwitch({
    required String paperId,
    String bizCode = '204',
  }) async {
    try {
      final response = await _client.get(
        ApiConstants.paperDownloadSwitchUrl,
        queryParameters: {
          'paperId': paperId,
          'bizCode': bizCode,
        },
        headers: _paperHeaders(
          'https://web.ewt360.com/answer-pc/exam/answer?paperId=$paperId&bizCode=$bizCode&platform=1&isRepeat=1',
        ),
      );
      return response.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// 触发服务端异步生成试卷 PDF 并返回下载 URL
  ///
  /// 对齐 Web "下载试卷" 按钮行为 (shared-hZ0qNeAu.DfQNTCF8.js):
  /// 1. GET https://pst.ewt360.com/api/print/async 触发生成, 返回 hashId
  /// 2. POST https://pst.ewt360.com/api/query/list/ids body {ids:[hashId]} 轮询
  ///    status=0 生成中 / status=1 成功 (filePath 为下载直链) / 其他 错误
  ///
  /// Web 端轮询间隔 1s (pollingInterval:1e3), 此处沿用。
  ///
  /// [paperId]  试卷 ID
  /// [title]    试卷标题 (用于服务端 PDF 文件名)
  /// [pdfType]  PDF 版本类型 (默认 'student' 学生版, 'teacher' 教师版含答案)
  /// [bizCode]  业务码 (默认 204)
  /// [token]    用户 token (拼接到 printTestPaper URL 中鉴权)
  /// [maxAttempts] 轮询最大次数 (默认 60, 每次间隔 1s, 总超时 60s)
  /// [onPoll]   每次轮询前回调 (attempt 从 0 开始), 用于 UI 更新进度
  ///
  /// 返回: {filePath: String, hashId: String, status: int}
  /// 失败抛 [NetworkException]。
  Future<Map<String, dynamic>> triggerServerPaperPdf({
    required String paperId,
    required String title,
    String pdfType = 'student',
    String bizCode = '204',
    String? token,
    int maxAttempts = 60,
    void Function(int attempt)? onPoll,
  }) async {
    final effectiveToken = token ?? _client.token ?? '';
    final printTestPaperUrl =
        'https://web.ewt360.com/answer-pc/printTestPaper?type=$pdfType'
        '&paperId=$paperId&bizCode=$bizCode&token=$effectiveToken';

    // ─── Step 1: 触发生成, 获取 hashId ───
    final triggerResp = await _client.rawRequest(
      'GET',
      '${ApiConstants.pstDomain}${ApiConstants.printAsyncUrl}',
      queryParameters: {
        'type': 'pdf',
        'modal': 'active',
        'name': title,
        'width': '1000',
        'url': printTestPaperUrl,
        'activeTriggerFuncName': 'PSTScreenshotHook',
      },
      headers: {
        'Accept': 'application/json, text/plain, */*',
        ...ApiHeaders.web,
      },
    );

    final triggerJson = _parseRawJson(triggerResp.data);
    if (triggerJson == null) {
      throw NetworkException('服务端试卷触发响应异常: ${triggerResp.data}');
    }

    final triggerData = triggerJson['data'];
    String hashId = '';
    String filePath = '';
    int status = 0;
    if (triggerData is Map<String, dynamic>) {
      hashId = triggerData['hashId']?.toString() ?? '';
      filePath = triggerData['filePath']?.toString() ?? '';
      final s = triggerData['status'];
      status = s is int ? s : int.tryParse(s.toString()) ?? 0;
    }

    // 触发即已生成 (缓存命中), 直接返回
    if (status == 1 && filePath.isNotEmpty) {
      return {'filePath': filePath, 'hashId': hashId, 'status': 1};
    }

    if (hashId.isEmpty) {
      throw NetworkException('服务端试卷触发未返回 hashId: $triggerJson');
    }

    // ─── Step 2: 轮询 /api/query/list/ids 直到 status=1 ───
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      onPoll?.call(attempt);

      final pollResp = await _client.rawRequest(
        'POST',
        '${ApiConstants.pstDomain}${ApiConstants.printQueryListIdsUrl}',
        data: jsonEncode({'ids': [hashId]}),
        headers: {
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/json',
          ...ApiHeaders.web,
        },
      );

      final pollJson = _parseRawJson(pollResp.data);
      if (pollJson == null) {
        throw NetworkException('服务端试卷轮询响应异常: ${pollResp.data}');
      }

      final pollData = pollJson['data'];
      if (pollData is List && pollData.isNotEmpty) {
        final first = pollData.first;
        if (first is Map<String, dynamic>) {
          filePath = first['filePath']?.toString() ?? '';
          final s = first['status'];
          status = s is int ? s : int.tryParse(s.toString()) ?? -1;

          if (status == 1 && filePath.isNotEmpty) {
            return {'filePath': filePath, 'hashId': hashId, 'status': 1};
          }
          if (status != 0) {
            final errCode = first['errCode']?.toString() ?? '';
            final errMsg = first['errMsg']?.toString() ?? '';
            throw NetworkException('服务端试卷生成失败 (status=$status, '
                'errCode=$errCode, errMsg=$errMsg)');
          }
        }
      }

      // status=0 生成中, 等待 1s 后重试 (对齐 Web pollingInterval:1e3)
      if (attempt < maxAttempts - 1) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    throw NetworkException('服务端试卷生成超时 (已轮询 $maxAttempts 次)');
  }

  /// 解析 rawRequest 返回的数据 (responseType: plain → String, 需手动 JSON 解码)
  dynamic _parseRawJson(dynamic data) {
    if (data is Map || data is List) return data;
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  // ─── 内部方法 ───

  /// 处理 answer API 响应 (以 success 布尔字段判断)
  ///
  /// 注意: ApiResponse.fromJson 已将原始 JSON 的 data 字段提取到 response.data,
  /// 此处直接透传即可, 不可再取 data['data'] (双重提取会得到 null)。
  Map<String, dynamic> _handleAnswerResponse(ApiResponse response) {
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return {
        'success': response.isSuccess || data['success'] == true,
        'message': response.msg.isNotEmpty ? response.msg : (data['msg'] ?? ''),
        'data': data,
      };
    }
    return {
      'success': response.isSuccess,
      'message': response.msg,
      'data': data,
    };
  }
}
