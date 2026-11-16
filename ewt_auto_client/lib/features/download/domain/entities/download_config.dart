/// 下载配置实体（视频/试题共用），仅含课程级过滤配置与视频下载线路选择。
/// 试题 PDF 走服务端生成，不再使用本地字体配置。
library;

import 'package:flutter/foundation.dart';

import '../../../answer/domain/entities/answer_filter_config.dart';
import '../../../player/domain/services/video_source_resolver.dart';

/// 下载配置 (视频/试题共用)
///
/// 仅包含课程级过滤配置。试题 PDF 下载走服务端生成, 不再使用本地字体配置。
@immutable
class DownloadConfig {
  /// 课程级过滤配置 (复用 AnswerFilterConfig 的字段结构)
  final AnswerFilterConfig filterConfig;

  /// 视频下载线路 (仅视频下载使用)
  ///
  /// - [VideoLine.auto]: 自动 (优先腾讯云, 失败回退阿里云)
  /// - [VideoLine.tencent]: 强制腾讯云 VOD
  /// - [VideoLine.aliyun]: 强制阿里云 VOD
  final VideoLine videoLine;

  const DownloadConfig({
    this.filterConfig = const AnswerFilterConfig(),
    this.videoLine = VideoLine.auto,
  });

  DownloadConfig copyWith({
    AnswerFilterConfig? filterConfig,
    VideoLine? videoLine,
  }) {
    return DownloadConfig(
      filterConfig: filterConfig ?? this.filterConfig,
      videoLine: videoLine ?? this.videoLine,
    );
  }
}
