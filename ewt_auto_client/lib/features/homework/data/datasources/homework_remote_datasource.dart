/// 作业远程数据源，封装作业列表、作业任务分页列表及课程任务信息等 homeworkprod 接口。
/// 失败统一抛 NetworkException，鉴权/签名由 DioClient 拦截器自动完成。
library;

import '../../../../core/constants/api_constants.dart';
import '../../../../core/network/dio_client.dart';

/// 作业远程数据源
///
/// 对应 Python: core/homework.py HomeworkMixin
class HomeworkRemoteDataSource {
  final DioClient _client;

  HomeworkRemoteDataSource(this._client);

  /// 获取作业列表
  ///
  /// POST /api/homeworkprod/homework/student/getStudentHomeworkInfo
  Future<List<dynamic>> getHomeworkList({
    required String schoolId,
    int? subject,
    int? type,
    int? status,
    int pageIndex = 1,
    int pageSize = 20,
  }) async {
    final payload = <String, dynamic>{
      'schoolId': schoolId,
      'pageIndex': pageIndex,
      'pageSize': pageSize,
      'notClassSetting': 0,
      'status': status,
    };
    if (subject != null) payload['subject'] = subject;
    if (type != null) payload['type'] = type;

    final response = await _client.post(
      ApiConstants.homeworkListUrl,
      data: payload,
    );
    if (!response.isSuccess) {
      throw NetworkException('获取作业列表失败: ${response.msg}');
    }
    final data = response.data;
    if (data is List) return data;
    if (data is Map<String, dynamic>) {
      return (data['homeworkList'] ?? data['list']) as List<dynamic>? ?? [];
    }
    return [];
  }

  /// 获取作业任务列表（分页）
  ///
  /// POST /api/homeworkprod/student/homework/task/pageHomeworkTasks
  Future<Map<String, dynamic>> getHomeworkTasks({
    required String homeworkId,
    required String schoolId,
    String? dayId,
    List<int>? mustLearnSubjectList,
    int pageIndex = 1,
    int pageSize = 30,
  }) async {
    final payload = <String, dynamic>{
      'schoolId': schoolId,
      'homeworkId': homeworkId,
      'mustLearnSubjectList':
          mustLearnSubjectList ?? List.generate(12, (i) => i + 1),
      'queryMustLearn': 1,
      'pageIndex': pageIndex,
      'pageSize': pageSize,
    };
    if (dayId != null && dayId.isNotEmpty) {
      payload['dayId'] = dayId;
    }
    final response = await _client.post(
      ApiConstants.homeworkTasksUrl,
      data: payload,
    );
    if (!response.isSuccess) {
      throw NetworkException('获取任务列表失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 获取每日科目统计
  ///
  /// POST /api/homeworkprod/student/homework/task/getStudentHomeworkDaySubjectStat
  /// 返回 {subjectStat: [...], dateStat: [...]}
  Future<Map<String, dynamic>> getDaySubjectStat({
    required String homeworkId,
    required String schoolId,
    List<int>? mustLearnSubjectList,
  }) async {
    final response = await _client.post(
      ApiConstants.dayStatUrl,
      data: {
        'schoolId': schoolId,
        'homeworkId': homeworkId,
        'mustLearnSubjectList':
            mustLearnSubjectList ?? List.generate(12, (i) => i + 1),
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取统计失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>? ?? {};
  }

  /// 更新任务状态
  ///
  /// POST /api/homeworkprod/homework/student/updateMission
  Future<void> updateMission({
    required String homeworkId,
    required String missionId,
    required int status,
  }) async {
    final response = await _client.post(
      ApiConstants.updateMissionUrl,
      data: {
        'homeworkId': homeworkId,
        'missionId': missionId,
        'status': status,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('更新任务状态失败: ${response.msg}');
    }
  }

  /// 查询任务进度
  ///
  /// POST /api/homeworkprod/homework/student/taskProgressV1
  Future<Map<String, dynamic>> getTaskProgress({
    required String homeworkId,
    required String taskId,
  }) async {
    final response = await _client.post(
      ApiConstants.taskProgressUrl,
      data: {
        'homeworkId': homeworkId,
        'taskId': taskId,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('查询进度失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 检查作业有效性
  ///
  /// GET /api/homeworkprod/homework/student/getHomeworkValid
  Future<bool> checkHomeworkValid({
    required String homeworkId,
  }) async {
    final response = await _client.get(
      ApiConstants.homeworkValidUrl,
      queryParameters: {'homeworkId': homeworkId},
    );
    if (!response.isSuccess) return false;
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data['valid'] == true || data['valid'] == 1;
    }
    return false;
  }

  /// 获取课程讲次详情
  ///
  /// POST /api/homeworkprod/player/getLessonDetailV2
  ///
  /// 注意: schoolId/lessonId/homeworkId 转为 int 类型传入,
  /// 与 getStudyGuideAndPractice 保持一致, 避免参数含特殊字符 (如 %)
  /// 导致 Dio 构建 URI 时触发 "Illegal percent encoding in URI" 异常。
  Future<Map<String, dynamic>> getLessonDetail({
    required String schoolId,
    required String lessonId,
    String? homeworkId,
  }) async {
    final payload = <String, dynamic>{
      'schoolId': int.tryParse(schoolId) ?? 0,
      'lessonId': int.tryParse(lessonId) ?? 0,
    };
    if (homeworkId != null && homeworkId.isNotEmpty) {
      payload['homeworkId'] = int.tryParse(homeworkId) ?? 0;
    }
    final response = await _client.post(
      ApiConstants.lessonDetailUrl,
      data: payload,
    );
    if (!response.isSuccess) {
      throw NetworkException('获取课程详情失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>? ?? {};
  }

  /// 获取播放器 Token
  ///
  /// POST /api/homeworkprod/player/getPlayerToken
  Future<String> getPlayerToken({
    required String schoolId,
    required String lessonId,
    int type = 1,
    int contentType = 1,
    String videoBizCode = '1013',
  }) async {
    final response = await _client.post(
      ApiConstants.playerTokenUrl,
      data: {
        'schoolId': schoolId,
        'lessonId': lessonId,
        'type': type,
        'contentType': contentType,
        'videoBizCode': videoBizCode,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取播放令牌失败: ${response.msg}');
    }
    return response.data?.toString() ?? '';
  }

  /// 获取外部视频信息（视频源列表）
  ///
  /// GET /api/videoplayerprod/videoplayer/getExternalVideoInfo
  Future<List<dynamic>> getExternalVideoInfo({
    required String lessonId,
    required String videoToken,
    String videoBizCode = '1013',
    String sdkVersion = '3.0.37',
  }) async {
    final response = await _client.get(
      ApiConstants.externalVideoInfoUrl,
      queryParameters: {
        'videoBizCode': videoBizCode,
        'lessonId': lessonId,
        'videoToken': videoToken,
        'sdkVersion': sdkVersion,
        '_': DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取视频信息失败: ${response.msg}');
    }
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data['videoList'] as List<dynamic>? ?? [];
    }
    return [];
  }
}
