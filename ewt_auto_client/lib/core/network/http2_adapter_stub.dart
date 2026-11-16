/// HTTP/2 适配器 Web 平台占位 (dart:io 不可用): 返回 null,
/// 由 DioClient 回退浏览器原生 HTTP 栈。条件导入的 stub 端。
library;

import 'package:dio/dio.dart';

/// Web 平台占位: HTTP/2 适配器依赖 dart:io 不可用。
///
/// 返回 null, 调用方 ([DioClient._rebuildAdapter]) 回退默认适配器,
/// 即浏览器原生 HTTP 栈 (自动协商 HTTP/2, 此处无需干预)。
HttpClientAdapter? createHttp2Adapter() => null;
