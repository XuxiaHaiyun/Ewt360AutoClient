/// 周培优远程数据源：封装周培优权限校验、用户信息、班级教材列表、
/// 班级/课程安排与视频列表等接口（对应 Python core/weekend.py WeekendMixin）。
library;

import '../../../../core/constants/api_constants.dart';
import '../../../../core/network/dio_client.dart';

/// 周培优远程数据源
///
/// 对应 Python: core/weekend.py WeekendMixin
class WeekendRemoteDataSource {
  final DioClient _client;

  WeekendRemoteDataSource(this._client);

  /// 检查周培优权限
  ///
  /// GET /api/weekend/commonservice/checkuserauth?platform=1&userId=xxx
  /// 返回 {ispass: bool, weekendurl: String, ...}
  Future<Map<String, dynamic>> checkUserAuth({
    required String userId,
  }) async {
    final response = await _client.get(
      ApiConstants.weekendCheckAuthUrl,
      queryParameters: {'platform': 1, 'userId': userId},
    );
    if (!response.isSuccess) {
      throw NetworkException('检查周培优权限失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>? ?? {};
  }

  /// 获取周培优用户信息
  ///
  /// GET /api/weekend/trainingtop/userinfo
  Future<Map<String, dynamic>> getUserInfo() async {
    final response = await _client.get(ApiConstants.weekendUserInfoUrl);
    if (!response.isSuccess) {
      throw NetworkException('获取周培优用户信息失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 获取班级教材列表
  ///
  /// GET /api/weekend/trainingtop/classbooklist
  Future<List<dynamic>> getClassBookList({
    required String classId,
  }) async {
    final response = await _client.get(
      ApiConstants.weekendClassBookListUrl,
      queryParameters: {'classId': classId, 'bookId': 0},
    );
    if (!response.isSuccess) {
      throw NetworkException('获取教材列表失败: ${response.msg}');
    }
    return response.data as List<dynamic>? ?? [];
  }

  /// 获取学校全部周培优班级 (越权模式)
  ///
  /// GET /api/weekend/classSchedule/monthly/todo?classId=&graduationYear=
  /// 当 classId / graduationYear 均置空时, 服务端返回学校全部班级:
  /// data = { noContentList[], hasContentList[], noScheduleList[] }
  /// 三个列表的元素结构一致: { classId, className, scheduleId, ... }
  Future<List<Map<String, dynamic>>> getMonthlyTodoClasses() async {
    final response = await _client.get(
      ApiConstants.weekendMonthlyTodoUrl,
      queryParameters: {
        'classId': '',
        'graduationYear': '',
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取全部班级失败: ${response.msg}');
    }
    final data = response.data as Map<String, dynamic>? ?? {};
    final classes = <Map<String, dynamic>>[];
    for (final key in ['hasContentList', 'noContentList', 'noScheduleList']) {
      final list = data[key];
      if (list is List) {
        for (final item in list) {
          if (item is Map<String, dynamic> &&
              (item['classId'] != null || item['className'] != null)) {
            classes.add(item);
          }
        }
      }
    }
    return classes;
  }

  /// 获取课程表
  ///
  /// GET /api/weekend/student/front/v2/schedule/scheduleList
  Future<List<dynamic>> getScheduleList({
    required String bookId,
  }) async {
    final response = await _client.get(
      ApiConstants.weekendScheduleListUrl,
      queryParameters: {'bookId': bookId},
    );
    if (!response.isSuccess) {
      throw NetworkException('获取课程表失败: ${response.msg}');
    }
    return response.data as List<dynamic>? ?? [];
  }

  /// 获取章节课程详情
  ///
  /// GET /api/weekend/student/front/v2/course/chapterDetail/courseDetail
  /// 返回 {mainCourse, paperPractice, extraPractice[], evaluatePractice}
  Future<Map<String, dynamic>> getCourseDetail({
    required String chapterId,
    required String classId,
    int platform = 1,
  }) async {
    final response = await _client.get(
      ApiConstants.weekendCourseDetailUrl,
      queryParameters: {
        'chapterId': chapterId,
        'classId': classId,
        'platform': platform,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取课程详情失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>? ?? {};
  }

  /// 获取视频详情
  ///
  /// GET /api/weekend/video/detail
  Future<Map<String, dynamic>> getVideoDetail({
    required String videoId,
  }) async {
    final response = await _client.get(
      ApiConstants.weekendVideoDetailUrl,
      queryParameters: {'videoId': videoId},
    );
    if (!response.isSuccess) {
      throw NetworkException('获取视频详情失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// 获取教材库筛选选项
  ///
  /// GET /api/weekend/commonservice/bookoptionlist
  /// 返回 {trainTypeList, subjectList, stageList, publishingHouseList, versionList}
  Future<Map<String, dynamic>> getBookOptionList() async {
    final response = await _client.get(ApiConstants.weekendBookOptionListUrl);
    if (!response.isSuccess) {
      throw NetworkException('获取教材筛选选项失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>? ?? {};
  }

  /// 获取教材列表
  ///
  /// GET /api/weekend/book/list?subjectId=&classId=&searchName=
  /// 返回 {openedBookList, bookInfoList:[{trainingType, trainingName, bookList:[...]}]}
  /// 注意: 阶段/出版社/版本/层次 由前端按 bookName 解析后过滤,
  /// 服务端仅按 subjectId/classId/searchName 过滤。
  Future<Map<String, dynamic>> getBookList({
    required String subjectId,
    required String classId,
    String searchName = '',
  }) async {
    final response = await _client.get(
      ApiConstants.weekendBookListUrl,
      queryParameters: {
        'subjectId': subjectId,
        'classId': classId,
        'searchName': searchName,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取教材列表失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>? ?? {};
  }

  /// 获取周练错题解析任务详情
  ///
  /// GET /api/weekend/student/flow/v2/wrongQuestionTask/detail
  /// ?chapterId=&platform=1&classId=
  /// 返回: {paperId, list: [{courseId, lessonId, lessonName, lessonIsComplete}]}
  Future<Map<String, dynamic>> getWrongQuestionDetail({
    required String chapterId,
    required String classId,
    int platform = 1,
  }) async {
    final response = await _client.get(
      ApiConstants.weekendWrongQuestionDetailUrl,
      queryParameters: {
        'chapterId': chapterId,
        'className': '',
        'classId': classId,
        'platform': platform,
      },
    );
    if (!response.isSuccess) {
      throw NetworkException('获取周练错题解析失败: ${response.msg}');
    }
    return response.data as Map<String, dynamic>? ?? {};
  }
}
