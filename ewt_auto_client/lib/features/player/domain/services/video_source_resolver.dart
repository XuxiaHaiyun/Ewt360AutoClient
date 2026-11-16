/// 视频源解析器：从 getPlayInfo / getPlayerToken 等接口解析出可播放地址，
/// 支持腾讯云 VOD(DRM HLS) 与阿里云 VOD(MP4 直链/私有加密 HLS) 多线路、多档清晰度。
/// 阿里云加密档位携带 keyBase64（_vpk），供本地解密代理/下载解密使用。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/network/api_helper.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/network/network_logger.dart';
import '_sce_cipher.dart';

/// 视频线路 (视频源提供商)
///
/// - [auto]: 自动 (优先腾讯云 VOD, 失败回退阿里云 VOD)
/// - [tencent]: 强制腾讯云 VOD (DRM HLS m3u8)
/// - [aliyun]: 强制阿里云 VOD (MP4 直链 / 私有加密 HLS)
enum VideoLine { auto, tencent, aliyun }

/// 阿里云私有加密类型标识 (PlayConfig.EncryptType / 响应 EncryptType)
const String _aliyunEncryptType = 'AliyunVoDEncryption';

/// 视频清晰度档位
///
/// [label] 展示名 (原画/高清/标清/1080P 等, 无法识别时用"档位N"),
/// [url] 该档位可播放地址 (m3u8 / MP4 直链)。
/// [keyBase64] 阿里云私有加密 (AliyunVoDEncryption) 档位的 AES 解密密钥
/// (base64 的 16 字节 `_vpk`), 由 [SceCipher.deriveVpk] 从该档的
/// Rand/Plaintext 派生 —— 注意它**不是**整段 HLS 的 AES-128 key, 而是
/// 每个 TS 分片内 PES 负载的 AES-128-ECB 密钥 (见 [SceTsSampleDecryptor]);
/// 非加密档位为 null。
class ResolvedVideoQuality {
  final String label;
  final String url;
  final String? keyBase64;

  const ResolvedVideoQuality({required this.label, required this.url, this.keyBase64});

  @override
  String toString() => 'ResolvedVideoQuality($label)';
}

/// 视频源解析结果
///
/// [url] 最终可播放/下载的地址 (m3u8 或 MP4 直链)
/// [drmToken] 腾讯云 DRM token (阿里云 MP4 直链为空字符串)
/// [format] 'm3u8' 或 'mp4' (小写)
/// [line] 实际选中的线路 (腾讯云/阿里云), 供播放器判断真实来源。
/// [fallbacks] 阿里云线路内备用转码档 URL 列表, 当首选播放解码失败时
///   在同线路内降档重试 (不切腾讯云), 避免 mpv 对部分原片音轨解码失败。
/// [keyBase64] 选中档位的阿里云私有加密解密密钥 (非加密为 null)
/// [qualities] 全部清晰度档位 (首项 = 默认选中, 与 [url] 相同);
///   仅一项或空时播放器不显示清晰度切换入口。
/// [aliyunEncrypted] 阿里云线路选中的码流为 AliyunVoDEncryption 私有加密
///   (EXT-X-KEY 的 URI 为密钥块)。该类流采用**样本级加密**: TS 容器明文,
///   PES 负载用 `_vpk` 做 AES-128-ECB 加密 —— 第三方播放器可"播放"但画面是
///   乱码 ([keyBase64] + SceTsSampleDecryptor 解密后才可用, 下载路径已支持),
///   实时播放仍需回退腾讯云线路。
///
/// 关键: [VideoLine.auto] 时由 [VideoSourceResolver.resolve] 内部决定走腾讯
/// 还是阿里云, 但返回结果需携带实际 [line], 否则调用方无法感知 auto 是否落到了
/// 阿里云 (这直接决定"阿里云解码失败时能否自动回退")。
class ResolvedVideoSource {
  final String url;
  final String drmToken;
  final String format;
  final VideoLine line;
  final List<String> fallbacks;
  final String? keyBase64;
  final bool aliyunEncrypted;
  final List<ResolvedVideoQuality> qualities;

  const ResolvedVideoSource({
    required this.url,
    this.drmToken = '',
    this.format = 'mp4',
    this.line = VideoLine.auto,
    this.fallbacks = const [],
    this.keyBase64,
    this.aliyunEncrypted = false,
    this.qualities = const [],
  });

  bool get isM3u8 =>
      url.toLowerCase().contains('m3u8') || format == 'm3u8';

  @override
  String toString() =>
      'ResolvedVideoSource(url: ${url.length > 80 ? '${url.substring(0, 80)}...' : url}, '
      'drmToken: ${drmToken.isEmpty ? '<empty>' : '${drmToken.length}字符'}, format: $format)';
}

/// 视频源解析器
///
/// 从 [PlayerRemoteDataSource.getExternalVideoInfo] 返回的 `videoInfo` 中
/// 解析出最终可播放/下载的地址。对齐 Python `core/homework.py` 与
/// ewtdownloader/js/ewt-api.js 的实现:
///
///  - 优先腾讯云 VOD (showPlat=5): getplayinfo/v4 返回 m3u8 + drmToken
///  - 回退阿里云 VOD: HMAC-SHA1 签名 GetPlayInfo 返回 MP4 直链
///
/// 此类从 [DownloadService] 提取, 供下载与实时点播共用。
///
/// 关键: 请求腾讯云/阿里云时使用独立的 [_extDio] (无拦截器, 二进制安全),
/// 避免主 DioClient 的 Sign/Auth 拦截器破坏响应或注入无关 headers。
class VideoSourceResolver {
  final DioClient _client;

  /// 外部请求专用 Dio (无拦截器, bytes 响应)
  ///
  /// DioClient 的 _dio 使用 ResponseType.plain + Sign/Auth 拦截器,
  /// 会破坏二进制数据 (TS 段/DRM key) 并向 CDN 注入无关 headers。
  /// 此实例对齐 Python 的 requests.get: 纯净 HTTP, 二进制安全。
  final Dio _extDio;

  /// 解析过程中的日志回调 (可选)
  final void Function(String message, {bool warning})? onLog;

  VideoSourceResolver({
    required DioClient client,
    this.onLog,
  })  : _client = client,
        _extDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 2),
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        )) {
    // 纳入网络日志范围（腾讯云/阿里云 VOD 解析请求）
    NetworkLogger.attach(_extDio);
  }

  void _log(String msg, {bool warning = false}) =>
      onLog?.call(msg, warning: warning);

  /// 解析播放地址
  ///
  /// [line] 指定线路:
  ///   - [VideoLine.auto]: 优先腾讯云 VOD (showPlat=5), 失败回退阿里云 VOD (默认)
  ///   - [VideoLine.tencent]: 仅尝试腾讯云 VOD
  ///   - [VideoLine.aliyun]: 仅尝试阿里云 VOD
  ///
  /// 对齐 ewtdownloader/js/ewt-api.js getVideoUrlFull:
  ///   showPlat=5 存在 → 试腾讯云, 失败 → 落入阿里云 fallback
  ///   阿里云作为兜底 (不检查 showPlat=4, [_getAliyunPlayInfo] 内部遍历所有项)
  Future<ResolvedVideoSource?> resolve(
      Map<String, dynamic> videoInfo, {VideoLine line = VideoLine.auto}) async {
    final videoList = (videoInfo['videoList'] as List<dynamic>?) ?? [];
    if (videoList.isEmpty) return null;

    // 强制腾讯云线路
    if (line == VideoLine.tencent) {
      return _getTcVodPlayInfo(videoInfo);
    }
    // 强制阿里云线路
    if (line == VideoLine.aliyun) {
      return _getAliyunPlayInfo(videoInfo);
    }

    // 自动: 对齐 JS: videoList.some(v => v.showPlat === 5)
    final hasTcvod = videoList.any((v) =>
        v is Map && (v['showPlat'] == 5 || v['showPlat'].toString() == '5'));

    _log('  视频源: ${videoList.length} 个, 含腾讯云VOD=$hasTcvod');

    if (hasTcvod) {
      final play = await _getTcVodPlayInfo(videoInfo);
      if (play != null && play.url.isNotEmpty) return play;
      _log('  腾讯云VOD 解析失败, 回退阿里云VOD', warning: true);
    }

    // 对齐 JS: 阿里云作为兜底, 无条件尝试 (不检查 showPlat=4)
    return _getAliyunPlayInfo(videoInfo);
  }

  /// 腾讯云 VOD: 取 showPlat=5 的 appId/fileId/psign, 调 getplayinfo/v4
  ///
  /// 对齐 ewtdownloader/js/tcvod.js _extractInfo + getPlayInfo:
  ///   - 仅处理 showPlat===5 (严格数值比较) 的首项
  ///   - appId = String(platFormUuId)
  ///   - psign = definitionList[0].psign
  ///   - 响应取 drmOutput[0].url (不选最高清晰度)
  ///   - code!==0 抛错, drmToken/drmOutput 为空抛错
  Future<ResolvedVideoSource?> _getTcVodPlayInfo(
      Map<String, dynamic> videoInfo) async {
    final videoList = (videoInfo['videoList'] as List<dynamic>?) ?? [];

    // 对齐 JS _extractInfo: 找首个 showPlat===5 且 appId/fileId/psign 齐全的项
    String? appId;
    String? fileId;
    String? psign;
    for (final v in videoList) {
      if (v is! Map) continue;
      // JS 用 === 严格数值比较; Dart JSON 解析后 showPlat 可能是 int 或 String
      final sp = v['showPlat'];
      if (sp != 5 && sp.toString() != '5') continue;
      appId = (v['platFormUuId'] ?? '').toString();
      fileId = (v['videoId'] ?? '').toString();
      final defListRaw = v['definitionList'];
      final defList = defListRaw is List ? defListRaw : <dynamic>[];
      psign = defList.isNotEmpty && defList[0] is Map
          ? (defList[0]['psign'] ?? '').toString()
          : '';
      if (appId.isNotEmpty && fileId.isNotEmpty && psign.isNotEmpty) break;
      appId = fileId = psign = null;
    }

    if (appId == null ||
        appId.isEmpty ||
        fileId == null ||
        fileId.isEmpty ||
        psign == null ||
        psign.isEmpty) {
      _log('  腾讯云VOD: 未提取到 showPlat=5 的 appId/fileId/psign',
          warning: true);
      return null;
    }

    final pi =
        await _getPlayInfo(psign: psign, appId: appId, fileId: fileId);
    if (pi == null || pi['code'] != 0) {
      _log(
          '  腾讯云VOD getplayinfo 失败: '
          '${pi?['message'] ?? pi?['msg'] ?? pi ?? 'null'}',
          warning: true);
      return null;
    }

    final mediaRaw = pi['media'];
    final media = mediaRaw is Map ? mediaRaw : <String, dynamic>{};
    final streamingRaw = media['streamingInfo'];
    final streaming =
        streamingRaw is Map ? streamingRaw : <String, dynamic>{};
    final drmToken = (streaming['drmToken'] ?? '').toString();
    final drmOutputsRaw = streaming['drmOutput'];
    final drmOutputs =
        drmOutputsRaw is List ? drmOutputsRaw : <dynamic>[];

    if (drmOutputs.isEmpty) {
      _log('  腾讯云VOD: drmOutput 为空', warning: true);
      return null;
    }
    if (drmToken.isEmpty) {
      _log('  腾讯云VOD: drmToken 为空', warning: true);
      return null;
    }

    // 对齐 JS: 默认取 drmOutput[0]; 全部档位以清晰度列表暴露供播放器切换
    final first = drmOutputs.first;
    final url = (first is Map ? (first['url'] ?? '') : '').toString();
    if (url.isEmpty) {
      _log('  腾讯云VOD: drmOutput[0].url 为空', warning: true);
      return null;
    }

    final qualities = tencentQualitiesFrom(drmOutputs);
    _log('  腾讯云VOD: ${qualities.length} 个清晰度档位'
        '${qualities.length > 1 ? ' (${qualities.map((q) => q.label).join('/')})' : ''}');

    return ResolvedVideoSource(
        url: url,
        drmToken: drmToken,
        format: 'm3u8',
        line: VideoLine.tencent,
        qualities: qualities);
  }

  /// 调用腾讯云 VOD getplayinfo/v4 接口
  ///
  /// 对齐 ewtdownloader/js/tcvod.js getPlayInfo:
  ///   URL: https://playvideo.qcloud.com/getplayinfo/v4/{appId}/{fileId}?psign=...
  ///   不传 keyId (JS 参考实现不传, Python 传 keyId=1 但 requests 过滤 None)
  /// Response: {code: 0, media: {streamingInfo: {drmToken, drmOutput: [...]}}}
  Future<Map<String, dynamic>?> _getPlayInfo({
    required String psign,
    required String appId,
    required String fileId,
  }) async {
    final url = '${ApiConstants.playvideoDomain}/getplayinfo/v4/$appId/$fileId';
    try {
      final response = await _extDio.get<List<int>>(
        url,
        queryParameters: {
          'psign': psign,
        },
        options: Options(headers: _tcVodHeaders),
      );
      // 对齐 Python: requests 不会因 4xx/5xx 抛出 (由调用方检查 code)
      if (response.statusCode != null && response.statusCode! >= 400) {
        final body = _decodeJsonResponse(response.data);
        _log(
            '  腾讯云VOD HTTP ${response.statusCode}: '
            '${body?['code'] ?? ""} ${body?['message'] ?? body?['msg'] ?? ""}',
            warning: true);
        return body;
      }
      return _decodeJsonResponse(response.data);
    } catch (e) {
      _log('  腾讯云VOD 请求异常: ${_truncateError(e)}', warning: true);
      return null;
    }
  }

  /// 阿里云 VOD: 遍历 videoList 提取 STS, 签名调用 GetPlayInfo
  ///
  /// 对齐 ewtdownloader/js/aliyun-vod.js _extractSTS + getPlayInfo:
  ///   - 不检查 showPlat (遍历所有项, 靠 psign 解码成败过滤)
  ///   - vid = VideoMeta.VideoId || sts.VideoId || vItem.videoId
  ///   - 必须传 AuthInfo 参数 (控制播放鉴权, 影响 MP4/m3u8 返回)
  ///   - 错误判定: result.Code 存在即错误
  ///   - 优先 MP4, 否则取首个
  ///
  /// 私有加密 (AliyunVoDEncryption) 链路额外分两步走:
  ///   1. 列表模式 (ResultType=Multiple) 枚举出全部可用的 Definition 档位;
  ///   2. 逐档以 Definition + Rand 再请求一次, 拿到该档的 Rand/Plaintext,
  ///      交给 [SceCipher.deriveVpk] 解出真正的 16 字节 HLS 密钥。
  /// 服务端不会单独下发最终密钥, 只下发"被客户端密钥材料加密过的素材"。
  Future<ResolvedVideoSource?> _getAliyunPlayInfo(
      Map<String, dynamic> videoInfo) async {
    final credentials = _collectAliyunCredentials(videoInfo);
    if (credentials.isEmpty) {
      _log('  阿里云VOD: 未提取到 STS 凭证', warning: true);
      return null;
    }
    final cred = credentials.first;

    _log(
        '  阿里云VOD: videoId=${cred.videoId}, region=${cred.region}, '
        'keyId=${cred.sts['AccessKeyId'].toString().isEmpty ? '<空>' : '${cred.sts['AccessKeyId'].toString().substring(0, 6)}...'}'
        '${credentials.length > 1 ? ' (共 ${credentials.length} 份凭证)' : ''}');

    try {
      final encrypted =
          _aliyunEncrypted(videoInfo) || (videoInfo['encryptType'] is String);

      // ── 1. 列表模式: 枚举全部码流 (私有加密时 Plaintext 为空) ──
      final listed = await _requestAliyunPlayInfo(cred, videoInfo: videoInfo);
      if (listed == null) return null;
      final streams = _aliyunPlayInfosOf(listed);
      if (streams.isEmpty) {
        _log('  阿里云VOD: PlayInfoList 为空', warning: true);
        return null;
      }

      final listEncrypted = streams.any(
          (p) => (p['EncryptType'] ?? '').toString() == _aliyunEncryptType);

      // 非加密 (MP4 直链等): 列表模式已足够, 直接走原有解析
      if (!encrypted && !listEncrypted) {
        return _parseAliyunPlayInfo(streams, _log);
      }

      // ── 2. 私有加密: 逐 Definition 取密钥素材 ──
      //
      // 服务端对每份 Definition 响应独立的 Rand/Plaintext (均绑定本次请求的
      // 客户端密钥材料), 因此每个清晰度都要单独生成一次 l/Rand。
      final definitions = <String>[];
      for (final p in streams) {
        final d = (p['Definition'] ?? '').toString();
        if (d.isNotEmpty && !definitions.contains(d)) definitions.add(d);
      }
      if (definitions.isEmpty) {
        _log('  阿里云VOD: 列表响应未给出 Definition, 无法按档取密钥',
            warning: true);
        return _parseAliyunPlayInfo(streams, _log);
      }

      final keysByUrl = <String, String>{};
      final derived = <Map>[]; // 带真实密钥的码流条目, 用于构建清晰度列表
      var acquired = 0;

      for (final def in definitions) {
        final secret = SceCipher.genClientSecret();
        final rand = SceCipher.deriveRand(secret);
        if (rand == null) continue;
        final scoped = await _requestAliyunPlayInfo(
          cred,
          videoInfo: videoInfo,
          definition: def,
          rand: rand,
          encryptType: _aliyunEncryptType,
          quiet: true,
        );
        if (scoped == null) continue;
        for (final p in _aliyunPlayInfosOf(scoped)) {
          final url = (p['PlayURL'] ?? '').toString();
          final resRand = (p['Rand'] ?? '').toString();
          final plain = (p['Plaintext'] ?? '').toString();
          if (url.isEmpty || resRand.isEmpty || plain.isEmpty) continue;
          final key = SceCipher.deriveVpkBase64(
            secret: secret,
            rand: resRand,
            plaintext: plain,
          );
          if (base64.decode(key).length != 16) {
            _log('  阿里云VOD $def: 派生密钥长度异常, 跳过', warning: true);
            continue;
          }
          keysByUrl[url] = key;
          derived.add(p);
          acquired++;
        }
      }

      if (acquired == 0) {
        _log('  阿里云VOD: 未取得任何私有加密密钥, 降级为无密钥播放源',
            warning: true);
        return _parseAliyunPlayInfo(streams, _log);
      }

      _log('  阿里云VOD: 已派生 $acquired 个私有加密档位的 AES 密钥');
      final merged = derived.isNotEmpty ? derived : streams;
      return _parseAliyunPlayInfo(merged, _log, derivedKeys: keysByUrl);
    } catch (e) {
      _log('  阿里云VOD 解析失败: ${_truncateError(e)}', warning: true);
      return null;
    }
  }

  /// 收集全部可用 STS 凭证 (每个清晰度一份独立 psign)
  ///
  /// 优先保留能解析出 AccessKeyId 的 psign; 顺序保持 videoList → definitionList。
  List<_AliyunCredential> _collectAliyunCredentials(
      Map<String, dynamic> videoInfo) {
    final out = <_AliyunCredential>[];
    final videoList = (videoInfo['videoList'] as List<dynamic>?) ?? [];

    for (final v in videoList) {
      if (v is! Map) continue;
      final defListRaw = v['definitionList'];
      final defList = defListRaw is List ? defListRaw : <dynamic>[];
      for (final d in defList) {
        final psign = d is Map ? (d['psign'] ?? '').toString() : '';
        if (psign.isEmpty) continue;
        final sts = _decodeAliyunPsign(psign);
        if (sts == null || sts['AccessKeyId'] == null) continue;
        out.add(_AliyunCredential(
          sts: sts,
          videoId: _stsVideoId(sts, v),
          region: (sts['Region'] ?? v['region'] ?? 'cn-beijing').toString(),
        ));
      }
    }

    // Fallback: videoInfo 顶层字段 (对齐 JS _extractSTS 末尾兜底)
    if (out.isEmpty) {
      final akId = videoInfo['AccessKeyId'] ?? videoInfo['accessKeyId'];
      if (akId != null) {
        out.add(_AliyunCredential(
          sts: {
            'AccessKeyId': akId.toString(),
            'AccessKeySecret':
                (videoInfo['AccessKeySecret'] ?? videoInfo['accessKeySecret'] ?? '')
                    .toString(),
            'SecurityToken':
                (videoInfo['SecurityToken'] ?? videoInfo['securityToken'] ?? '')
                    .toString(),
            'AuthInfo':
                (videoInfo['AuthInfo'] ?? videoInfo['authInfo'] ?? '').toString(),
          },
          videoId: (videoInfo['vid'] ??
                  videoInfo['Vid'] ??
                  videoInfo['videoId'] ??
                  '')
              .toString(),
          region: (videoInfo['Region'] ?? videoInfo['region'] ?? 'cn-beijing')
              .toString(),
        ));
      }
    }
    return out;
  }

  /// 从 STS 中定位 videoId: VideoMeta.VideoId → VideoId → AuthInfo.MediaId
  /// → videoList 条目的 videoId
  String _stsVideoId(Map<String, dynamic> sts, Map fallbackEntry) {
    String pick(Object? v) => (v ?? '').toString();

    final meta = sts['VideoMeta'];
    if (meta is Map) {
      final id = pick(meta['VideoId']);
      if (id.isNotEmpty) return id;
    }
    final direct = pick(sts['VideoId']);
    if (direct.isNotEmpty) return direct;

    final auth = sts['AuthInfo'];
    if (auth != null) {
      try {
        final decoded = jsonDecode(auth.toString());
        if (decoded is Map) {
          final mediaId = pick(decoded['MediaId']);
          if (mediaId.isNotEmpty) return mediaId;
        }
      } catch (_) {}
    }
    return pick(fallbackEntry['videoId']);
  }

  /// 发起一次签名后的 GetPlayInfo 请求
  ///
  /// [definition]+[rand] 非空时进入播放模式 (服务端下发该档密钥素材);
  /// [quiet] 为 true 时不打印失败日志 (逐档探测时避免刷屏)。
  Future<Map<String, dynamic>?> _requestAliyunPlayInfo(
    _AliyunCredential cred, {
    required Map<String, dynamic> videoInfo,
    String? definition,
    String? rand,
    String? encryptType,
    bool quiet = false,
  }) async {
    final params = buildAliyunPlayInfoParams(
      sts: cred.sts,
      videoId: cred.videoId,
      region: cred.region,
      definition: definition,
      rand: rand,
      encryptType: encryptType,
      videoInfo: videoInfo,
    );
    final fullUrl = buildAliyunPlayInfoUrl(
      params,
      (cred.sts['AccessKeySecret'] ?? '').toString(),
      cred.region,
    );

    // 对齐 JS: fetch(url) 无自定义 headers
    final response = await _extDio.get<List<int>>(fullUrl);
    final json = _decodeJsonResponse(response.data);
    // 对齐 JS: if (result.Code) throw (Code 存在即错误)
    if (json == null || json['Code'] != null) {
      if (!quiet) {
        _log(
            '  阿里云VOD 错误: ${json?['Code'] ?? 'null'} '
            '${json?['Message'] ?? ''}',
            warning: true);
      }
      return null;
    }
    return json;
  }

  /// 取响应中的 PlayInfoList.PlayInfo[]
  static List<Map> _aliyunPlayInfosOf(Map<String, dynamic> json) {
    final raw = (json['PlayInfoList'] is Map)
        ? (json['PlayInfoList'] as Map)['PlayInfo']
        : null;
    final list = raw is List ? raw : <dynamic>[];
    return list.whereType<Map>().toList();
  }

  /// 解析 GetPlayInfo 响应 → 播放源 (多档清晰度 + 加密密钥)
  ///
  /// 收集全部码流 (MP4 + m3u8), 排序: MP4 > m3u8 > 原片, 同档内按高度降序。
  ///
  /// [derivedKeys] 为 PlayURL → 真实 16 字节 AES 密钥 (base64) 的映射, 由
  /// [SceCipher.deriveVpk] 从各档的 Rand/Plaintext 派生; 提供时优先用它作
  /// `keyBase64`, 否则退化使用响应里未解密的 Plaintext (拿不到最终密钥)。
  static ResolvedVideoSource? _parseAliyunPlayInfo(
    List<Map> playInfoList,
    void Function(String message, {bool warning})? log, {
    Map<String, String>? derivedKeys,
  }) {
    if (playInfoList.isEmpty) {
      log?.call('  阿里云VOD: PlayInfoList 为空', warning: true);
      return null;
    }

    final candidates = <Map>[];
    for (final p in playInfoList) {
      if ((p['PlayURL'] ?? '').toString().isEmpty) continue;
      candidates.add(p);
    }
    if (candidates.isEmpty) {
      log?.call('  阿里云VOD: PlayInfoList 无有效条目', warning: true);
      return null;
    }
    String? plainKeyOf(Map m) {
      final url = (m['PlayURL'] ?? '').toString();
      final derived = derivedKeys?[url];
      if (derived != null && derived.isNotEmpty) return derived;
      final plain = (m['Plaintext'] ?? '').toString();
      return plain.isEmpty ? null : plain;
    }

    int heightOf(Map m) => _numField(m, const ['Height', 'height']);

    int playRank(Map m) {
      final d = (m['Definition'] ?? '').toString();
      final dl = d.toLowerCase();
      final isOd = d.isEmpty ||
          dl == 'od' ||
          dl == 'original' ||
          d.contains('原片') ||
          d.contains('片源');
      if (isOd) return 2; // 原片最后 (解码兼容差)
      final fmt = (m['Format'] ?? '').toString().toLowerCase();
      if (fmt == 'mp4') return 0; // MP4 直链最稳
      return 1; // m3u8 (含私有加密, 播放器携带 Plaintext 解密)
    }

    final ordered = List<Map>.of(candidates)..sort((a, b) {
        final r = playRank(a).compareTo(playRank(b));
        if (r != 0) return r;
        return heightOf(b).compareTo(heightOf(a)); // 同档内清晰度高的在前
      });

    final selected = ordered.first;
    final playUrl = (selected['PlayURL'] ?? '').toString();
    final fallbacks = ordered
        .skip(1)
        .map((p) => (p['PlayURL'] ?? '').toString())
        .where((u) => u.isNotEmpty)
        .toList();
    final qualities = aliyunQualitiesFrom(ordered, derivedKeys: derivedKeys);
    final keyBase64 = plainKeyOf(selected);
    log?.call(
        '  阿里云VOD: ${candidates.length} 个码流, ${qualities.length} 个清晰度档位'
        '${qualities.length > 1 ? ' (${qualities.map((q) => q.label).join('/')})' : ''}'
        '${keyBase64 != null ? ', 私有加密(含解密密钥)' : ''}'
        '${fallbacks.isNotEmpty ? ', 备用转码档 ${fallbacks.length} 个' : ''}');

    final selectedEncrypt = ((selected['Encrypt'] ?? '').toString() == '1' ||
        (selected['EncryptType'] ?? '').toString() == 'AliyunVoDEncryption');
    return ResolvedVideoSource(
      url: playUrl,
      drmToken: '',
      format: (selected['Format'] ?? 'mp4').toString().toLowerCase(),
      line: VideoLine.aliyun,
      fallbacks: fallbacks,
      keyBase64: keyBase64,
      aliyunEncrypted: selectedEncrypt,
      qualities: qualities,
    );
  }

  // ─── 清晰度档位构建 (纯函数, 离线可测) ───

  /// 腾讯云 drmOutput 列表 → 清晰度档位 (首项 = 默认选中)
  ///
  /// 条目字段防御式解析 (definition/height), url 为空的条目跳过,
  /// 无法识别定义时回退 "档位N" (N 为有效条目序号)。
  static List<ResolvedVideoQuality> tencentQualitiesFrom(
      List<dynamic> outputs) {
    final out = <ResolvedVideoQuality>[];
    for (final e in outputs) {
      if (e is! Map) continue;
      final url = (e['url'] ?? '').toString();
      if (url.isEmpty) continue;
      out.add(ResolvedVideoQuality(
        label: _qualityLabel(e, fallback: '档位${out.length + 1}'),
        url: url,
      ));
    }
    return out;
  }

  /// 阿里云已排序码流条目 → 清晰度档位 (首项 = 默认选中, 与 ordered 排序一致)
  ///
  /// [derivedKeys] 为 PlayURL → 真实 16 字节 AES 密钥 (base64); 命中时用它,
  /// 否则退回条目的 Plaintext 字段 (未解密素材, 第三方播放器用不了)。
  static List<ResolvedVideoQuality> aliyunQualitiesFrom(
    List<Map> ordered, {
    Map<String, String>? derivedKeys,
  }) {
    final out = <ResolvedVideoQuality>[];
    for (final e in ordered) {
      final url = (e['PlayURL'] ?? '').toString();
      if (url.isEmpty) continue;
      final derived = derivedKeys?[url];
      final plain = (e['Plaintext'] ?? '').toString();
      final key = (derived != null && derived.isNotEmpty)
          ? derived
          : (plain.isEmpty ? null : plain);
      out.add(ResolvedVideoQuality(
        label: _qualityLabel(e, fallback: '档位${out.length + 1}'),
        url: url,
        keyBase64: key,
      ));
    }
    return out;
  }

  /// 构造阿里云 GetPlayInfo 签名请求参数 (对齐站点 mst-player 抓包)
  ///
  /// [definition] 非空时进入**播放模式**: 服务端只返回该清晰度一个码流, 但会为该
  /// 码流下发 `Rand` + `Plaintext` 密钥素材 (前提是请求携带合法 [rand]);
  /// 此时**不能**带 `ResultType` (站点抓包: 带 Definition 时无 ResultType)。
  ///
  /// [definition] 为空时为**列表模式**: 必须带 `ResultType=Multiple` (否则私有加密
  /// 视频直接 403 Forbidden.AliyunVoDEncryption), 返回全部码流但 `Plaintext` 为空
  /// —— 只用于枚举可用清晰度, 拿不到密钥。
  ///
  /// [rand] 为 [SceCipher.deriveRand] 产出的客户端密钥密文; 服务端会用私钥解出
  /// 客户端密钥材料并据此派生 (加密) 下发的 `Plaintext`。自造随机字节会被拒:
  /// `400 InvalidParameter The specified parameter "Rand" is not valid.`
  ///
  /// [encryptType] 非空时携带 `PlayConfig={"EncryptType":...}` (私有加密必须)。
  static Map<String, String> buildAliyunPlayInfoParams({
    required Map<String, dynamic> sts,
    required String videoId,
    required String region,
    String? definition,
    String? rand,
    String? encryptType,
    Map<String, dynamic> videoInfo = const {},
  }) {
    var type = (encryptType ?? '').trim();
    if (type.isEmpty) type = (videoInfo['encryptType'] ?? '').toString().trim();
    if (type.isEmpty && _aliyunEncrypted(videoInfo)) type = _aliyunEncryptType;
    final params = <String, String>{
      'Action': 'GetPlayInfo',
      'AccessKeyId': (sts['AccessKeyId'] ?? '').toString(),
      'SecurityToken': (sts['SecurityToken'] ?? '').toString(),
      // 关键: AuthInfo 控制播放鉴权, 传了才返回 CDN 可播地址, 不传返回受保护 m3u8
      'AuthInfo': (sts['AuthInfo'] ?? '').toString(),
      'VideoId': videoId,
      'AuthTimeout': '7200',
      'Format': 'JSON',
      'Version': '2017-03-21',
      'SignatureMethod': 'HMAC-SHA1',
      'SignatureVersion': '1.0',
      'SignatureNonce': const Uuid().v4().replaceAll('-', ''),
      // 站点 mst-player 同款参数: Channel/PlayerVersion 固定;
      // 私有加密视频须带 PlayConfig.EncryptType (对齐站点抓包)。
      'Channel': 'HTML5',
      'PlayerVersion': 'plugin-1.5.2',
      if (rand != null && rand.isNotEmpty) 'Rand': rand,
      if (definition != null)
        // 播放模式: 精确限定清晰度, 服务端才下发该档密钥素材
        'Definition': definition
      else
        // 列表模式: 必须带 ResultType=Multiple (否则加密视频报 Forbidden,
        // 提示"use the Aliyun player or set ResultType to Multiple")
        'ResultType': 'Multiple',
      if (type.isNotEmpty) 'PlayConfig': '{"EncryptType":"$type"}',
    };
    return params;
  }

  /// 构造签名后的完整请求 URL
  static String buildAliyunPlayInfoUrl(
    Map<String, String> params,
    String accessKeySecret,
    String region,
  ) {
    final signature = _aliyunSign(params, accessKeySecret);
    final query = params.keys.toList()..sort();
    final queryStr = query
        .map((k) => '${_aliyunEnc(k)}=${_aliyunEnc(params[k]!)}')
        .join('&');
    return 'https://vod.$region.aliyuncs.com/?$queryStr'
        '&Signature=${_aliyunEnc(signature)}';
  }

  /// 移除私有加密 m3u8 里那个"陷阱" `#EXT-X-KEY` 行 (纯函数, 离线可测)
  ///
  /// 阿里云私有加密 (AliyunVoDEncryption) **不是**整段 AES-128: 实测 TS 容器
  /// 本身是明文 (首字节 0x47), 被加密的是每个 PES 负载 (AES-128-ECB, 密钥为
  /// [SceCipher.deriveVpk] 产出的 `_vpk`)。m3u8 里的
  /// `#EXT-X-KEY:MEATHOD=AES-128,URI="<base64块>"` 只是给标准播放器看的诱饵
  /// —— `MEATHOD` 是阿里云的拼写缺陷, 标准解析器读不到 `METHOD=`。
  ///
  /// 因此正确做法不是"注入密钥", 而是**删掉这一行**, 再配合
  /// [SceTsSampleDecryptor] 做样本级解密。
  ///
  /// [baseUrl] 非空时把相对分片 URI 补全为绝对 URL。
  static String stripHlsKey({
    required String playlist,
    String? baseUrl,
  }) {
    Uri? base = baseUrl == null ? null : Uri.tryParse(baseUrl);
    final out = <String>[];
    for (var rawLine in playlist.split('\n')) {
      var line = rawLine;
      final t = line.trim();
      if (t.startsWith('#EXT-X-KEY')) {
        continue; // 丢弃整行
      } else if (t.isNotEmpty && !t.startsWith('#') && base != null) {
        line = base.resolve(t.trim()).toString();
      }
      out.add(line);
    }
    return out.join('\n');
  }

  /// 重写加密 HLS 播放列表的解密密钥 (纯函数, 离线可测)
  ///
  /// 适用于**整段 AES-128 加密**的 HLS (例如腾讯云 SimpleAES 线路需要换 key):
  /// 把 `#EXT-X-KEY` 的 URI 替换为 [keyUri] (native 可用
  /// `data:application/octet-stream;base64,<key>`, web 用 blob: URL)。
  ///
  /// 注意: 阿里云私有加密**不适用**本方法 (它不整段解密, 且 `MEATHOD` 拼写
  /// 缺陷会让标准解析器忽略整行) —— 那种流请用 [stripHlsKey] +
  /// [SceTsSampleDecryptor]。
  ///
  /// - 修正 MEATHOD → METHOD 拼写错误;
  /// - [baseUrl] 非空时把相对分片 URI 补全为绝对 URL (playlist 以 blob
  ///   注入播放器时 base 变化, 必需)。
  static String rewriteHlsKey({
    required String playlist,
    required String keyUri,
    String? baseUrl,
  }) {
    Uri? base = baseUrl == null ? null : Uri.tryParse(baseUrl);
    final out = <String>[];
    for (var rawLine in playlist.split('\n')) {
      var line = rawLine;
      final t = line.trim();
      if (t.startsWith('#EXT-X-KEY')) {
        line = line.replaceFirst(RegExp(r'MEATHOD\s*='), 'METHOD=');
        line = line.replaceFirst(RegExp(r'URI="[^"]*"'), 'URI="$keyUri"');
        if (!line.contains('METHOD=')) {
          // 极端情况: 行内无 METHOD 且替换失败, 注入最小 KEY 行
          line = '#EXT-X-KEY:METHOD=AES-128,URI="$keyUri"';
        }
      } else if (t.isNotEmpty && !t.startsWith('#') && base != null) {
        final abs = base.resolve(t.trim());
        line = abs.toString();
      }
      out.add(line);
    }
    return out.join('\n');
  }

  /// 通用清晰度标签: height → definition (命名/数值) → fallback
  static String _qualityLabel(Map e, {required String fallback}) {
    final height = _numField(e, const ['height', 'Height', 'renderHeight']);
    if (height > 0) return '${height}P';
    final def = (e['definition'] ?? e['Definition'] ?? '').toString();
    return _defName(def) ?? fallback;
  }

  static int _numField(Map e, List<String> keys) {
    for (final k in keys) {
      final v = e[k];
      if (v is num && v > 0) return v.toInt();
      final p = int.tryParse(v?.toString() ?? '');
      if (p != null && p > 0) return p;
    }
    return 0;
  }

  /// 清晰度定义名 → 中文展示名 (未识别返回 null)
  ///
  /// 阿里云命名: OD 原画 / FD 全高清 / HD 高清 / SD 标清 / LD 流畅;
  /// 腾讯云数值定义: 0 原画 / 10 流畅 / 20 标清 / 30 高清 / 40 全高清。
  static String? _defName(String def) {
    final d = def.trim().toLowerCase();
    if (d.isEmpty) return null;
    const named = {
      'od': '原画',
      'fd': '全高清',
      'hd': '高清',
      'sd': '标清',
      'ld': '流畅',
    };
    if (named[d] != null) return named[d];
    const numeric = {
      '0': '原画',
      '10': '流畅',
      '20': '标清',
      '30': '高清',
      '40': '全高清',
    };
    if (numeric[d] != null) return numeric[d];
    return null;
  }

  // ─── 阿里云 VOD 辅助 ───

  /// videoInfo 是否声明为加密视频 (isEncryption/encryptType 顶层字段)
  static bool _aliyunEncrypted(Map<String, dynamic> videoInfo) {
    final enc = videoInfo['isEncryption'];
    final encTrue = enc == true || enc.toString() == '1' || enc.toString() == 'true';
    final encType = (videoInfo['encryptType'] ?? '').toString();
    return encTrue || encType.isNotEmpty;
  }

  /// psign 为 base64(JSON) 的 STS 凭证, 解出完整 STS Map
  ///
  /// 对齐 ewtdownloader/js/aliyun-vod.js _decodePsignSTS:
  ///   - 补齐 base64 padding
  ///   - atob 解码 (标准 base64)
  ///   - JSON.parse
  ///   - 任何异常返回 null
  /// 返回完整 STS Map (含 AccessKeyId/AccessKeySecret/SecurityToken/VideoId/AuthInfo/Region)
  Map<String, dynamic>? _decodeAliyunPsign(String psign) {
    try {
      var padded = psign;
      while (padded.length % 4 != 0) {
        padded += '=';
      }
      List<int> bytes;
      try {
        bytes = base64.decode(padded);
      } catch (_) {
        // URL-safe base64 回退
        final urlSafe = padded.replaceAll('-', '+').replaceAll('_', '/');
        bytes = base64.decode(urlSafe);
      }
      final data = jsonDecode(utf8.decode(bytes));
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      // 静默返回 null (对齐 JS: catch(e) { return null; })
      return null;
    }
  }

  /// 阿里云 RPC 签名: HMAC-SHA1, base64
  ///
  /// 对齐 Python: _aliyun_sign
  static String _aliyunSign(Map<String, String> params, String secret) {
    final sortedKeys = params.keys.toList()..sort();
    final canonical = sortedKeys
        .map((k) => '${_aliyunEnc(k)}=${_aliyunEnc(params[k]!)}')
        .join('&');
    // 对齐 Python: "GET&" + enc("/") + "&" + enc(canonical)
    final stringToSign = 'GET&${_aliyunEnc('/')}&${_aliyunEnc(canonical)}';
    final hmacSha1 = Hmac(sha1, utf8.encode('$secret&'));
    final digest = hmacSha1.convert(utf8.encode(stringToSign));
    return base64.encode(digest.bytes);
  }

  /// RFC 3986 百分号编码 (对齐 Python: quote(s, safe="-_.~"))
  ///
  /// 仅保留 A-Za-z0-9 - _ . ~ 不编码, 其余全部编码
  static String _aliyunEnc(String s) {
    return Uri.encodeComponent(s)
        .replaceAll('+', '%20')
        .replaceAll('*', '%2A')
        .replaceAll('!', '%21')
        .replaceAll("'", '%27')
        .replaceAll('(', '%28')
        .replaceAll(')', '%29')
        .replaceAll('%7E', '~');
  }

  String _truncateError(Object e) {
    final s = e.toString();
    if (s.length <= 120) return s;
    final firstLine = s.split('\n').first;
    if (firstLine.length <= 120) return firstLine;
    return '${firstLine.substring(0, 117)}...';
  }

  // ─── 请求头 (供下载/播放共用) ───

  /// 下载/播放请求头 (HLS m3u8 / TS / DRM key)
  ///
  /// 对齐 ewtdownloader/js/downloader.js 的 DL_HEADERS:
  ///   Origin/Referer 必须用 teacher.ewt360.com (HLS CDN 校验 Origin,
  ///   www.ewt360.com 会被拒 403)。
  /// UA 用 EndpointConfig 的浏览器 UA (与网关请求一致), 不用 JS 里的移动端 UA。
  Map<String, String> get dlHeaders {
    final cfg = _client.endpointConfig;
    return {
      'User-Agent': cfg.userAgent,
      ...ApiHeaders.teacher,
      'Accept': '*/*',
      ...cfg.extraHeaders,
    };
  }

  /// 腾讯云 VOD getplayinfo/v4 请求头
  ///
  /// 对齐 Python: core/homework.py get_play_info 中的 headers
  /// 关键: playvideo.qcloud.com 校验 Origin/Referer, 必须用
  /// teacher.ewt360.com (与 Python 一致), 不是 www.ewt360.com。
  Map<String, String> get _tcVodHeaders {
    return {
      'User-Agent': _client.endpointConfig.userAgent,
      'sec-ch-ua-platform': '"Windows"',
      'sec-ch-ua':
          '"Not(A:Brand";v="8", "Chromium";v="144", "Microsoft Edge";v="144"',
      'DNT': '1',
      'sec-ch-ua-mobile': '?0',
      'Accept': '*/*',
      ...ApiHeaders.teacher,
      'Sec-Fetch-Site': 'cross-site',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Dest': 'empty',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
  }

  /// 解码二进制 JSON 响应 (对齐 Python: r.json())
  static Map<String, dynamic>? _decodeJsonResponse(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final text = utf8.decode(bytes);
      final data = jsonDecode(text);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// 向 URL 追加 token 参数 (对齐 Python: _append_token)
  ///
  /// token 值需 URL 编码, 对齐 JS encodeURIComponent
  static String appendToken(String url, String token) {
    if (token.isEmpty || url.contains('token=')) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}token=${Uri.encodeComponent(token)}';
  }
}

/// 阿里云 GetPlayInfo 所需的 STS 凭证 + 关联元信息
///
/// psign 是逐清晰度下发的 (每个 clarity 一份独立凭证), 因此按条目收集。
class _AliyunCredential {
  /// psign (base64 JSON) 解出的 STS: AccessKeyId/SecurityToken/AuthInfo/AccessKeySecret
  final Map<String, dynamic> sts;

  /// 阿里云视频 id (24 位 hex)
  final String videoId;

  /// VOD 区域 (如 cn-beijing), 决定请求域名 vod.<region>.aliyuncs.com
  final String region;

  const _AliyunCredential({
    required this.sts,
    required this.videoId,
    required this.region,
  });
}
