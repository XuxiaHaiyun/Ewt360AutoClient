/// 网络调优参数 (设置页"网络"栏的全局运行时配置)
///
/// 设置项变更时由 settings_provider 调用 [update] 同步到此处;
/// [RetryInterceptor] 在每次请求时实时读取重试参数 (无需重建客户端),
/// 证书校验/HTTP2 需要重建底层适配器, 由 DioClient 持有并响应变更。
class NetworkTuning {
  NetworkTuning._();

  /// 禁用 SSL 证书验证 (自签名证书/抓包场景)
  static bool trustAllCerts = false;

  /// 启用 HTTP/2 (仅全局客户端; 与代理/禁用证书验证互斥, 冲突时回退 HTTP/1.1)
  static bool enableHttp2 = false;

  /// 连接失败重试次数 (0 = 不重试)
  static int connectRetryCount = 0;

  /// 连接重试间隔 (ms)
  static int connectRetryIntervalMs = 1000;

  /// 批量更新 (null 字段保持原值)
  static void update({
    bool? trustAll,
    bool? http2,
    int? retryCount,
    int? retryIntervalMs,
  }) {
    if (trustAll != null) trustAllCerts = trustAll;
    if (http2 != null) enableHttp2 = http2;
    if (retryCount != null) connectRetryCount = retryCount.clamp(0, 5);
    if (retryIntervalMs != null) {
      connectRetryIntervalMs = retryIntervalMs.clamp(100, 10000);
    }
  }
}
