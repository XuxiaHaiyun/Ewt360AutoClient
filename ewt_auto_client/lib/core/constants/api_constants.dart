/// EWT360 API 端点常量
abstract final class ApiConstants {
  // ─── 域名 ───
  static const String gatewayDomain = 'https://gateway.ewt360.com';
  static const String videoDomain = 'https://web.ewt360.com';
  static const String monitorDomain = 'https://bfe.ewt360.com';
  static const String clogDomain = 'https://clog.ewt360.com';
  static const String dlogDomain = 'https://dlog.ewt360.com';
  static const String fallbackIpLogDomain = 'https://101.37.78.197:8081';
  static const String playvideoDomain = 'https://playvideo.qcloud.com';
  /// 试卷 PDF 异步生成服务 (print/async 返回 filePath + hashId)
  static const String pstDomain = 'https://pst.ewt360.com';

  // ─── 认证 ───
  static const String loginUrl = '/api/authcenter/v2/oauth/login/account';
  static const String logoutUrl = '/api/authcenter/oauth/logout';
  static const String qrcodeGenerateUrl =
      '/api/authcenter/v2/oauth/login/qrcode/generate';
  static const String qrcodeStatusUrl =
      '/api/authcenter/v2/oauth/login/qrcode/status';
  static const String safecenterControlTypeUrl =
      '/api/safecenter/business/control/type';
  static const String smsLoginSafecenterUrl =
      '/api/usercenter/user/login/sms/byLogin/safecenter';
  static const String smsLoginMobileUrl =
      '/api/usercenter/user/login/mobile/login';

  // ─── 注册（短信注册，与短信登录同构的 4 步流程） ───
  /// Step 2: 发送注册短信验证码（safecenter）
  static const String registerSmsSendUrl =
      '/api/usercenter/sms/send/verification/code/safecenter';
  /// Step 3: 校验短信验证码，返回 authenticationToken
  static const String registerCheckCodeUrl =
      '/api/usercenter/register/check/code/';
  /// Step 4: 创建账号
  static const String registerCreateUrl = '/api/usercenter/register/mobile';

  // ─── 用户 ───
  static const String userInfoUrl = '/api/usercenter/user/login/getUser';
  static const String baseInfoUrl = '/api/usercenter/user/baseinfo';
  static const String updateUserInfoUrl =
      '/api/usercenter/user/updateUserInfo';
  static const String updatePasswordUrl =
      '/api/usercenter/user/updatePassword';

  // ─── 改密（弱密码等登录拦截场景） ───
  /// 账号型改密端点（login 流程 isSetInitPassword=true 分支）
  /// POST body: { password, newPassword, validatePassword(均 AES 加密), checkToken }
  static const String changePasswordAccountUrl =
      '/api/authcenter/v2/oauth/login/account/change/password';
  /// 手机型改密端点（login 流程 isSetInitPassword=false 分支，web 实际触发分支）
  static const String changePasswordMobileUrl =
      '/api/usercenter/user/login/mobile/login/changePassword';

  // ─── 改密（账号中心主动改密，已登录状态） ───
  /// 账号中心"修改密码"端点（已登录状态下用旧密码改密，鉴权靠 session token）
  /// 来源: web `member-center` SPA `ChangePassword/service` →
  ///   POST /api/usercenter/user/operate/change/password
  /// body: { oldPassword, newPassword } (均 AES 加密，与登录密码加密一致)
  /// 注意: 与上面的弱密码改密端点不同，本端点无需 checkToken。
  static const String changePasswordLoggedInUrl =
      '/api/usercenter/user/operate/change/password';

  // ─── 学校 ───
  static const String schoolUserInfoUrl =
      '/api/eteacherproduct/school/getSchoolUserInfo';
  static const String schoolBaseInfoUrl =
      '/api/commondata/common/school/get/baseinfo';
  static const String teacherRoleInfoUrl =
      '/api/eteacherproduct/teacher/manage/queryTeacherRoleAndSchoolInfo';
  static const String homeworkDowngradeUrl =
      '/api/eteacherproduct/downgrade/homeworkDownGradeConfig';
  static const String focusCheckDowngradeUrl =
      '/api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig';

  // ─── 作业 ───
  static const String homeworkListUrl =
      '/api/homeworkprod/homework/student/getStudentHomeworkInfo';
  static const String homeworkTasksUrl =
      '/api/homeworkprod/student/homework/task/pageHomeworkTasks';
  static const String dayStatUrl =
      '/api/homeworkprod/student/homework/task/getStudentHomeworkDaySubjectStat';
  static const String studentHomeworkInfoUrl =
      '/api/homeworkprod/student/homework/task/getStudentHomeworkInfo';
  static const String homeworkValidUrl =
      '/api/homeworkprod/homework/student/getHomeworkValid';
  static const String updateMissionUrl =
      '/api/homeworkprod/homework/student/updateMission';
  static const String holidaySummaryUrl =
      '/api/homeworkprod/homework/student/holiday/getHomeworkSummaryInfo';
  static const String holidayDistributionUrl =
      '/api/homeworkprod/homework/student/holiday/getHomeworkDistribution';
  static const String holidayTasksUrl =
      '/api/homeworkprod/homework/student/holiday/pageHomeworkTasks';

  // ─── 播放器/视频 ───
  static const String playerTokenUrl =
      '/api/homeworkprod/player/getPlayerToken';
  static const String lessonDetailUrl =
      '/api/homeworkprod/player/getLessonDetailV2';
  static const String externalVideoInfoUrl =
      '/api/videoplayerprod/videoplayer/getExternalVideoInfo';
  static const String playerGlobalConfUrl =
      '/api/videoplayerprod/videoplayer/getPlayerGlobalConf';
  static const String interactiveConfigUrl =
      '/api/videoplayerprod/videoplayer/getInteractiveConfigDetail';
  static const String submitAnswerUrl =
      '/api/videoplayerprod/videoplayer/submitAnswer';

  // ─── 进度/遥测 ───
  static const String reportVideoPointUrl =
      '/api/homeworkprod/homework/student/reportVideoPoint';
  static const String taskProgressUrl =
      '/api/homeworkprod/homework/student/taskProgressV1';
  static const String refreshTaskProgressUrl =
      '/api/homeworkprod/student/homework/task/refreshTaskProgress';
  static const String lessonTaskInfoUrl =
      '/api/homeworkprod/homework/student/getUserHomeworkLessonTaskInfo';
  static const String recordSubmitUrl =
      '/api/studyprod/course/lesson/record/submit';
  /// FM 收听记录上报 (contentType=3, 不走视频 BFE 流程)
  /// POST /api/xinliprod/fm/record/submit  body: {fmId}
  /// 对齐 Web FM 播放页 onPlay 事件: 播放开始时上报一次即视为学习
  static const String fmRecordSubmitUrl =
      '/api/xinliprod/fm/record/submit';
  /// 板报任务完成上报 (contentType=5, 不走视频 BFE 流程)
  /// POST /api/homeworkprod/homework/student/updateMission
  /// body: {schoolId, contentId, contentType:5, percent:1}
  /// 对齐 Web 任务总览页点击板报"去查看"时的上报
  static const String updateMissionByContentUrl =
      '/api/homeworkprod/homework/student/updateMission';
  static const String addVideossUrl =
      '/api/homeworkprod/homework/student/addVideoss';
  /// 黑名单用户认真度检测/互动点上报接口 (对齐浏览器 ek 组件 reportVideoPoint)
  /// 与 addVideoss 参数完全一致, 仅 URL 不同
  static const String addVideocssUrl =
      '/api/homeworkprod/homework/student/addVideocss';
  static const String seriousCheckDownGradeConfigUrl =
      '/api/eteacherproduct/downgrade/getSeriousCheckDownGradeConfig';
  /// 查询用户是否在认真度检测黑名单 (对齐 mstplayer_seriousness_check_doc.md §3'.7.1)
  /// GET /api/homeworkprod/homework/student/getVideodp
  /// 返回: {success, code, msg, data: bool}  data=true → 用户已在黑名单, 走滑块型
  static const String videodpUrl =
      '/api/homeworkprod/homework/student/getVideodp';
  /// 上报黑名单事件 (反自动化检测命中时调用, 对齐 §3'.7.1)
  /// GET /api/homeworkprod/homework/student/addStudp
  static const String addStudpUrl =
      '/api/homeworkprod/homework/student/addStudp';
  /// cab 接口 (用途未知, 疑似检测点相关布尔开关, 对齐 §7.1 实测)
  /// GET /api/homeworkprod/homework/student/cab?schoolId=&lessonId=&homeworkId=
  static const String videocabUrl =
      '/api/homeworkprod/homework/student/cab';
  static const String monitorCollectUrl = '/monitor/web/collect/batch';
  static const String playbackProgressUrl = '/video/playbackProgress';

  // ─── 答案 ───
  static const String answerReportUrl = '/api/answerprod/web/answer/report';
  static const String answerSheetSubGroupUrl =
      '/api/answerprod/common/answer/sheet/getAnswerSheetSubGroup';
  static const String answerSheetInfoUrl =
      '/api/answerprod/common/answer/answerSheetInfo';
  static const String submitPaperUrl =
      '/api/answerprod/web/answer/submitpaper';
  /// 保存做题痕迹 (对齐 Web tempSaveAnswerNew)
  /// POST /api/answerprod/web/answer/submitAnswer
  static const String tempSaveAnswerNewUrl =
      '/api/answerprod/web/answer/submitAnswer';
  static const String questionAnalysisUrl =
      '/api/answerprod/web/answer/simple/question/analysis';
  static const String paperQuestionUrl =
      '/api/answerprod/common/paper/getPaperQuestionByPaperId';
  static const String answerPaperUrl = '/api/answerprod/web/answer/paper';
  /// 通过 paperId + 页面报告获取整卷题目 (answer-pc 正常取题入口)
  ///
  /// GET /api/answerprod/web/answer/paperQuestionGroup
  /// 参数: paperId, platform, reportId, bizCode, userId, homeworkId
  /// 响应 data.groups[].questions 包含完整题干/选项/subjective/子题, 一次拉全。
  static const String paperQuestionGroupUrl =
      '/api/answerprod/web/answer/paperQuestionGroup';
  /// 试卷下载开关 (触发服务端生成试卷 PDF)
  /// GET /api/answerprod/web/paper/dowload/switch?paperId={paperId}&bizCode=204
  static const String paperDownloadSwitchUrl =
      '/api/answerprod/web/paper/dowload/switch';
  /// 服务端试卷 PDF 异步生成 (触发)
  /// GET https://pst.ewt360.com/api/print/async?type=pdf&...&url={printTestPaperUrl}
  /// 响应: {code:"200", data: {hashId, filePath:"", status:0}} status=0 生成中
  static const String printAsyncUrl = '/api/print/async';
  /// 服务端试卷 PDF 状态轮询 (对齐 Web getPSTResult)
  /// POST https://pst.ewt360.com/api/query/list/ids  body: {ids:[hashId]}
  /// 响应: {code:"200", data:[{hashId, filePath, status, errCode, errMsg}]}
  ///   status=0 生成中 / status=1 成功 (filePath 为下载直链) / 其他 错误
  static const String printQueryListIdsUrl = '/api/query/list/ids';

  // ─── 错题收藏 ───
  static const String favoriteLabelListUrl = '/api/wrongquestion/label/list';
  static const String favoriteLabelCreateUrl =
      '/api/wrongquestion/label/create';
  static const String favoriteUpdateQuestionUrl =
      '/api/wrongquestion/label/updatequestion';
  static const String favoriteDeleteQuestionUrl =
      '/api/wrongquestion/label/deletequestion';
  static const String favoriteGetQuestionUrl =
      '/api/answerprod/web/wrongquestion/label/getquestion';
  static const String favoriteQuestionInfoUrl =
      '/api/answerprod/web/wrongquestion/collect/question/info';
  static const String favoriteQuestionAnalysisUrl =
      '/api/answerprod/web/wrongquestion/collect/question/analysis';

  // ─── 周培优 ───
  static const String weekendCheckAuthUrl =
      '/api/weekend/commonservice/checkuserauth';
  static const String weekendUserInfoUrl =
      '/api/weekend/trainingtop/userinfo';
  static const String weekendClassBookListUrl =
      '/api/weekend/trainingtop/classbooklist';
  static const String weekendScheduleListUrl =
      '/api/weekend/student/front/v2/schedule/scheduleList';
  static const String weekendScheduleStatusUrl =
      '/api/weekend/student/front/v2/schedule/selectScheduleStatus';
  /// 周培优月度课表待办 (越权: classId/graduationYear 置空 → 返回学校全部班级)
  /// GET /api/weekend/classSchedule/monthly/todo?classId=&graduationYear=
  /// data: { noContentList[], hasContentList[], noScheduleList[] } (元素含 classId/className)
  static const String weekendMonthlyTodoUrl =
      '/api/weekend/classSchedule/monthly/todo';
  static const String weekendCourseDetailUrl =
      '/api/weekend/student/front/v2/course/chapterDetail/courseDetail';
  /// 周练错题解析任务详情 (gateway 域)
  /// GET /api/weekend/student/flow/v2/wrongQuestionTask/detail?chapterId=&platform=1&classId=
  static const String weekendWrongQuestionDetailUrl =
      '/api/weekend/student/flow/v2/wrongQuestionTask/detail';
  static const String weekendVideoDetailUrl = '/api/weekend/video/detail';
  /// 教材库 - 筛选选项 (培训类型/学科/学段/出版社/版本)
  /// GET /api/weekend/commonservice/bookoptionlist
  static const String weekendBookOptionListUrl =
      '/api/weekend/commonservice/bookoptionlist';
  /// 教材库 - 书本列表 (仅按 subjectId/classId/searchName 服务端过滤,
  /// 阶段/出版社/版本/层次由前端按 bookName 解析后客户端过滤)
  /// GET /api/weekend/book/list?subjectId=&classId=&searchName=
  static const String weekendBookListUrl = '/api/weekend/book/list';
  static const String weekendProxyConfigUrl =
      '/api/weekendprod/network/proxy/config';

  // ─── 活动中心 / 签到 ───
  /// 自动签到
  /// POST body: { "nodeId": 1, "platform": "2" }
  /// 鉴权 / 签名由 AuthInterceptor / SignInterceptor 自动完成, 无需手动传 ?token=
  static const String checkinSignUrl =
      '/api/activitycenter/app/usersystem/sign/v2';

  // ─── 其他 ───
  static const String serverTimeUrl = '/api/commondata/server/gettime';
  static const String cosCredentialsUrl = '/fs/credentials/token';
}
