/// get_it 依赖注入: 暴露全局 getIt 并注册 EndpointConfig / DioClient 单例。
library;

import 'package:get_it/get_it.dart';

import '../config/endpoint_config.dart';
import '../network/dio_client.dart';

final getIt = GetIt.instance;

/// 注册全局依赖
void configureDependencies() {
  getIt.registerLazySingleton<EndpointConfig>(
    () => EndpointConfig.defaults(),
  );

  getIt.registerLazySingleton<DioClient>(
    () => DioClient(
      endpointConfig: getIt<EndpointConfig>(),
    ),
  );
}
