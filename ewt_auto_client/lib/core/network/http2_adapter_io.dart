/// HTTP/2 适配器 IO 平台实现: 基于 dio_http2_adapter 创建真实 HTTP/2 适配器。
library;

import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';

/// IO 平台: 真正的 HTTP/2 适配器 (基于 package:http2)
HttpClientAdapter? createHttp2Adapter() => Http2Adapter(ConnectionManager());
