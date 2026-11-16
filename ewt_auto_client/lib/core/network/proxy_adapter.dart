/// 代理适配跨平台入口: 按条件导入分发到 IO/Web 实现,
/// 为 Dio 配置 HTTP/SOCKS5 代理与证书策略 (Web 端静默忽略)。
library;

import 'package:dio/dio.dart';

import 'proxy_adapter_io.dart'
    if (dart.library.js_interop) 'proxy_adapter_web.dart' as impl;

/// 跨平台网络适配入口
///
/// - IO 平台: 通过 HttpClient.findProxy 让 Dio 走 HTTP 代理,
///   [trustAllCerts] 时设置 badCertificateCallback 跳过证书校验
/// - Web: 浏览器网络栈不可控, 静默忽略
///
/// [proxy] 格式: `host:port` 或 `http://host:port`; null/空串表示直连。
/// 重复调用会整体重建适配器, 支持运行时切换代理/证书策略。
void applyProxyAdapter(
  Dio dio,
  String? proxy, {
  bool trustAllCerts = false,
}) {
  impl.applyProxyAdapter(dio, proxy, trustAllCerts: trustAllCerts);
}
