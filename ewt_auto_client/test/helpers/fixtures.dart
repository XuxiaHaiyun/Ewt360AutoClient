/// 测试数据工厂 (Fixtures)
///
/// 为单元测试与 API 集成测试提供统一的构造数据:
///   - [apiOk] / [apiFail]: 模拟 EWT360 网关统一响应包装
///   - [buildHomeworkItem] / [buildDateStat] / [buildCourse]:
///     作业列表 / 每日统计 / 课程条目 (对齐真实接口字段)
///   - [buildVideoInfo]: getExternalVideoInfo 返回的视频源信息
///
/// 字段命名对齐真实 API (homeworkId/lessonId/taskId/contentType/subjectName...),
/// 与生产代码中的取值逻辑一一对应, 避免测试数据与真实数据脱节。
library;

/// 构造网关成功响应: {"success": true, "code": "200", "msg": "...", "data": ...}
Map<String, dynamic> apiOk({
  Object? data,
  String code = '200',
  String msg = '操作成功',
}) =>
    {
      'success': true,
      'code': code,
      'msg': msg,
      'data': data,
    };

/// 构造网关失败响应: {"success": false, "code": "500", "msg": "..."}
Map<String, dynamic> apiFail({
  String code = '500',
  String msg = '操作失败',
  Object? data,
}) =>
    {
      'success': false,
      'code': code,
      'msg': msg,
      'data': data,
    };

/// 作业列表条目 (getHomeworkList 返回)
Map<String, dynamic> buildHomeworkItem({
  String homeworkId = 'hw_001',
  String homeworkName = '数学周练',
  int status = 2,
}) =>
    {
      'homeworkId': homeworkId,
      'homeworkName': homeworkName,
      'status': status,
    };

/// 每日科目统计条目 (getDaySubjectStat.dateStat)
Map<String, dynamic> buildDateStat({
  String dateId = '2026-08-12',
  String dateName = '08-12',
}) =>
    {
      'dateId': dateId,
      'dateName': dateName,
    };

/// 课程条目 (getHomeworkTasks.data, 即 courses)
///
/// 关键字段: lessonId/taskId/contentType/subjectName/title,
/// 兼容 contentType=1 视频 / 2 试卷 等常见类型。
Map<String, dynamic> buildCourse({
  String title = '高一数学上',
  String lessonId = 'lesson_001',
  String taskId = 'task_001',
  String videoId = 'video_001',
  String subjectName = '数学',
  Object? contentType = 1,
  Object? taskStatus = 10,
  Object? homeworkFinishStatus = 0,
  Object? duration = 600,
  Map<String, dynamic>? extra,
}) =>
    {
      'title': title,
      'lessonId': lessonId,
      'taskId': taskId,
      'videoId': videoId,
      'subjectName': subjectName,
      'contentType': contentType,
      'taskStatus': taskStatus,
      'homeworkFinishStatus': homeworkFinishStatus,
      'duration': duration,
      ...?extra,
    };

/// getExternalVideoInfo 返回的视频源信息
///
/// [showPlat] 5=腾讯云 VOD, 4=阿里云 VOD
Map<String, dynamic> buildVideoInfo({
  int showPlat = 5,
  String videoId = 'video_001',
  String platFormUuId = '1500000000',
  String psign = 'b3N0c2lnbg==',
  int duration = 600,
  Map<String, dynamic>? extra,
}) =>
    {
      'videoList': [
        {
          'showPlat': showPlat,
          'videoId': videoId,
          'platFormUuId': platFormUuId,
          'definitionList': [
            {'psign': psign},
          ],
        },
      ],
      'duration': duration,
      ...?extra,
    };

/// 空视频源信息 (无 videoList)
Map<String, dynamic> buildEmptyVideoInfo() => {
      'videoList': <dynamic>[],
    };

/// 构造 UserSession JSON (与 test/accounts.json 格式一致)
Map<String, dynamic> buildSessionJson({
  String token = 'test_token_001',
  String userId = '10001',
  String schoolId = '10000',
  String? displayName = '测试账号',
}) =>
    {
      'token': token,
      'userId': userId,
      'schoolId': schoolId,
      'account': null,
      'displayName': displayName,
      'avatar': null,
      'schoolName': null,
      'provinceCode': null,
      'mobile': null,
    };
