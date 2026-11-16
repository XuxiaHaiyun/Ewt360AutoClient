/// 活动中心签到远程数据源，封装签到接口调用。
/// 鉴权与签名由 [DioClient] 拦截器自动完成，调用方无需附加 token 或 sign 参数。
library;

import '../../../../core/constants/api_constants.dart';
import '../../../../core/network/dio_client.dart';

/// 活动中心 - 签到远程数据源
///
/// 对应 Python: probe_combo.py §3 (签到)
/// 鉴权 / 签名由 [DioClient] 的 AuthInterceptor / SignInterceptor 自动完成,
/// 调用方无需手动附加 ?token= 或 sign 参数。
class CheckinRemoteDataSource {
  final DioClient _client;

  CheckinRemoteDataSource(this._client);

  /// 单次签到 (自动签到开关触发时仅调用一次)
  ///
  /// POST /api/activitycenter/app/usersystem/sign/v2
  /// body: { "nodeId": 1, "platform": "2" }
  ///
  /// 返回原始 [ApiResponse], 由上层按 code == '200' 判定成功。
  Future<ApiResponse<Map<String, dynamic>>> signOnce() async {
    return _client.post(
      ApiConstants.checkinSignUrl,
      data: {'nodeId': 1, 'platform': '2'},
    );
  }
}
