/// Web 平台代理适配占位: 浏览器网络栈不可控, 代理/证书配置静默忽略 (no-op)。
library;

import 'package:dio/dio.dart';

/// Web 平台的代理适配实现
///
/// 浏览器网络栈由系统/浏览器控制, 不支持为单个 Dio 实例指定代理或
/// 跳过证书校验。保持默认适配器 (直连), 静默忽略代理/证书配置。
void applyProxyAdapter(
  Dio dio,
  String? proxy, {
  bool trustAllCerts = false,
}) {
  // no-op
}
