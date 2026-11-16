/// 用户详情状态管理与 Riverpod Provider，并行拉取 getUser/baseinfo/班级信息三个接口。
/// 供首页展示用户资料，加载失败时记录 error 状态。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';

/// 用户详情状态
class UserProfileState {
  final Map<String, dynamic>? userData;
  final Map<String, dynamic>? baseInfo;
  final Map<String, dynamic>? classInfo;
  final bool isLoading;
  final String? error;

  const UserProfileState({
    this.userData,
    this.baseInfo,
    this.classInfo,
    this.isLoading = false,
    this.error,
  });

  UserProfileState copyWith({
    Map<String, dynamic>? userData,
    Map<String, dynamic>? baseInfo,
    Map<String, dynamic>? classInfo,
    bool? isLoading,
    String? error,
  }) {
    return UserProfileState(
      userData: userData ?? this.userData,
      baseInfo: baseInfo ?? this.baseInfo,
      classInfo: classInfo ?? this.classInfo,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// 用户详情 Notifier
///
/// 对应 Python: gui/interfaces/user_info.py 的数据获取逻辑
class UserProfileNotifier extends StateNotifier<UserProfileState> {
  final DioClient _client;

  UserProfileNotifier(this._client) : super(const UserProfileState());

  /// 加载用户详细信息
  Future<void> loadProfile() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      // 并行获取用户信息、baseinfo、班级信息
      final results = await Future.wait([
        _client.get<Map<String, dynamic>>(
          '/api/usercenter/user/login/getUser',
        ),
        _client.get<Map<String, dynamic>>(
          '/api/usercenter/user/baseinfo',
        ),
        _client.get<Map<String, dynamic>>(
          '/api/eteacherproduct/studentManage/getJoinedClassesAndExtendedInfo',
        ),
      ]);

      final userResp = results[0];
      final baseResp = results[1];
      final classResp = results[2];

      state = state.copyWith(
        userData: userResp.isSuccess ? userResp.data : null,
        baseInfo: baseResp.isSuccess ? baseResp.data : null,
        classInfo: classResp.isSuccess ? classResp.data : null,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }
}

final userProfileProvider =
    StateNotifierProvider<UserProfileNotifier, UserProfileState>((ref) {
  final client = getIt<DioClient>();
  return UserProfileNotifier(client);
});
