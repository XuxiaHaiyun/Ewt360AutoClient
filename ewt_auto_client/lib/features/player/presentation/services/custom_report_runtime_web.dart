/// CustomReportRuntime 的 Web 平台 stub：quickjs_engine 依赖 dart:ffi 无法在 Web 编译，
/// 所有方法直接抛出 ScriptRuntimeException 提示使用 Android/Windows 客户端。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/network/dio_client.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';
import '../dialogs/task_progress_dialog.dart';
import 'custom_report_runtime_types.dart';

/// Web 平台 stub: quickjs_engine 依赖 dart:ffi, 无法在 Web 编译
class CustomReportRuntimeImpl {
  CustomReportRuntimeImpl._();

  static CustomReportRuntimeImpl create({
    required DioClient client,
    required PlayerRemoteDataSource playerRemote,
    required TelemetryRemoteDataSource telemetryRemote,
    required EndpointConfig endpointConfig,
    required Map<String, dynamic> account,
    required Map<String, dynamic> task,
    required String sessionId,
    required String secret,
    required String clientIp,
    required int maxBatchSize,
    bool useBackup = false,
    String reportBackend = 'clog',
    required void Function(String msg, LogLevel level) onLog,
    required void Function(double ratio, String? message) onProgress,
    required void Function(Map<String, dynamic> detail) onDetail,
  }) {
    throw ScriptRuntimeException(
      '自定义进度上报脚本 (QuickJS) 不支持 Web 平台, 请使用 Android/Windows 客户端',
    );
  }

  Future<void> execute(String script, {Duration? totalTimeout}) async {
    throw ScriptRuntimeException('Web 平台不支持 QuickJS 脚本执行');
  }

  void dispose() {}
}
