/// OSS 上传服务，对齐 Web 端 answer-pc 上传流程：获取 STS 凭证、HMAC-SHA1 手工签名 OSS PUT、上报完成。
/// 关键约束：必须传 appName；上传须用 virtual-hosted 风格 URL 且 x-oss-object-acl=public-read，最终返回 CDN URL。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/network/api_helper.dart';
import '../../../../core/network/dio_client.dart';

/// OSS 上传服务
///
/// 对齐 Web 端的 OSS 上传流程 (answer-pc):
/// 1. GET https://gateway.ewt360.com/fs/credentials/token?appName=answer-pc 获取 STS 凭证
/// 2. 使用 STS 凭证签名 OSS PUT 请求, 上传图片字节
/// 3. POST https://gateway.ewt360.com/fs/upload/complete 上报文件信息 (可选)
///
/// 由于 Flutter 端不引入 ali-oss SDK, 采用手工签名 OSS PUT 的方式上传,
/// 签名算法: HMAC-SHA1 (RFC 2104), 与 OSS V1 签名兼容。
///
/// 实际接口响应结构 (2026-08-01 抓取自 answer-pc 试卷页):
/// ```json
/// {
///   "success": true, "code": 200, "msg": "ok",
///   "data": {
///     "ts": 1785568235837,
///     "bucket": "ewt-infrastructure",
///     "prefix": "resources/answer-pc/uploads/",
///     "region": "oss-cn-hangzhou",
///     "cdnBaseUrl": "https://cdn.ewt360.com",
///     "credentials": {
///       "accessKeyId": "STS.NZBLrbqvatNtqLwtDB5o8EsXz",
///       "accessKeySecret": "Lhb4oVqZsyvh5gRb3iZo...",
///       "expiration": "2026-08-01T07:25:13Z",
///       "securityToken": "CAIS..."
///     },
///     "endpoint": "oss-cn-hangzhou.aliyuncs.com",
///     "internalEndpoint": "oss-cn-hangzhou-internal.aliyuncs.com"
///   }
/// }
/// ```
///
/// 关键要点:
/// - 必须传 `appName` (answer-pc 页面对应 `answer-pc`), 否则返回 400 `appName 不能为空`
/// - 凭证字段嵌套在 `data.credentials` 下, 非顶层
/// - `endpoint` 不含协议头, 需补 `https://`
/// - `bucket` 是 `ewt-infrastructure` (非默认 `ewt360`)
/// - 最终可访问 URL 使用 CDN (`cdnBaseUrl + prefix + objectKey`),
///   对齐 Web 端 attachmentImages 格式 (OSS 对象 ACL 为 public-read, CDN 优先)
class OssUploadService {
  /// 应用名 (对应 answer-pc 页面), 也是 OSS 路径前缀的第一段
  ///
  /// 也可作为构造参数覆盖, 其它端点对应不同 appName:
  /// - answer / answer-pc / ewt / ewt360 / homework / bend / student / web / pc / tiku
  final String appName;

  final DioClient _client;

  OssUploadService(this._client, {this.appName = 'answer-pc'});

  /// STS 凭证缓存 (避免每次上传都请求)
  _StsCredentials? _cachedSts;
  DateTime? _cachedStsExpiry;

  /// 上传图片字节到 OSS, 返回可访问的 CDN URL
  ///
  /// [imageBytes] 图片字节 (PNG)
  /// [fileName] 文件名 (不含路径, 如 "answer_123.png")
  ///
  /// 返回: CDN URL (用于 attachmentImages 字段), 失败抛 [Exception]。
  Future<String> uploadImage(Uint8List imageBytes, String fileName) async {
    // 1. 获取 STS 凭证
    final sts = await _getStsCredentials();
    if (sts == null) {
      throw Exception('获取 STS 凭证失败');
    }

    // 2. 构造 OSS object key (对齐 Web: prefix/timestamp/fileName)
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final objectKey = '${sts.prefix}$timestamp-$fileName';

    // 3. 签名并上传到 OSS
    //
    // 必须使用虚拟主机风格 (virtual-hosted style) URL:
    //   https://{bucket}.{endpoint-host}/{objectKey}
    // 该 bucket (ewt-infrastructure) 配置了"禁止二级域名访问",
    // 用 path-style (https://{endpoint}/{bucket}/{objectKey}) 会被 OSS 拒绝:
    //   <Code>SecondLevelDomainForbidden</Code>
    //   "The bucket you are attempting to access must be addressed using OSS third level domain."
    // 这与 Web 端 ali-oss SDK 默认行为一致 (SDK 默认 virtual-hosted style)。
    //
    // 注意: 签名的 CanonicalizedResource 仍是 /{bucket}/{objectKey},
    //       virtual-hosted 与 path-style 在 OSS V1 签名中相同, 无需区分。
    final ossUploadUrl =
        '${sts.endpoint.replaceFirst('://', '://${sts.bucket}.')}/$objectKey';
    final contentMd5 = _base64Md5(imageBytes);
    final gmtDate = HttpDate.format(DateTime.now().toUtc());

    // OSS V1 签名
    final stringToSign = _buildStringToSign(
      method: 'PUT',
      contentMd5: contentMd5,
      contentType: 'image/png',
      date: gmtDate,
      securityToken: sts.securityToken,
      bucket: sts.bucket,
      objectKey: objectKey,
    );
    final signature = _hmacSha1Base64(sts.accessKeySecret, stringToSign);
    final authorization = 'OSS ${sts.accessKeyId}:$signature';

    // 4. PUT 上传
    //
    // 对齐 Web 端 EWTFileService.upload(file, path, {acl: "public-read"}):
    // - x-oss-object-acl 必须为 public-read (STS 策略仅允许 public-read,
    //   设为 private 会触发 403 AccessDenied)
    // - 不传 x-oss-forbid-overwrite (ali-oss SDK 默认不设, 避免 STS 策略问题)
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 60),
    ));
    try {
      final response = await dio.put(
        ossUploadUrl,
        data: imageBytes,
        options: Options(
          headers: {
            'Authorization': authorization,
            'Content-MD5': contentMd5,
            'Content-Type': 'image/png',
            'Content-Length': imageBytes.length,
            'Date': gmtDate,
            'x-oss-security-token': sts.securityToken,
            'x-oss-object-acl': 'public-read',
          },
        ),
      );
      if (response.statusCode != 200) {
        throw Exception('OSS 上传失败: HTTP ${response.statusCode}');
      }
    } on DioException catch (e) {
      // 透传 OSS 错误响应体 (含 <Code>SignatureDoesNotMatch</Code> /
      // <Code>AccessDenied</Code> 等), 便于诊断 403/404 等失败根因
      final body = e.response?.data;
      final bodyStr = body is String ? body : body?.toString();
      throw Exception('OSS 上传异常: ${e.message}'
          '${bodyStr != null && bodyStr.isNotEmpty ? ' | body: $bodyStr' : ''}');
    } finally {
      dio.close();
    }

    // 5. 构造最终可访问 URL (CDN URL)
    //    对齐 Web 端: OSS 对象 ACL 为 public-read (CDN 与 OSS 直连均可访问),
    //    优先返回 CDN URL (cdnBaseUrl + prefix + objectKey) 以匹配 Web 端 attachmentImages 格式;
    //    若 cdnBaseUrl 缺失, 回退到 OSS 直连 URL。
    final cdnUrl = sts.cdnBaseUrl.isNotEmpty
        ? '${sts.cdnBaseUrl}/$objectKey'
        : ossUploadUrl;

    // 6. 上报文件信息 (非关键步骤, 失败不影响上传结果)
    await _reportUploadComplete(
      fileUrl: cdnUrl,
      fileSize: imageBytes.length,
      fileName: fileName,
    );

    return cdnUrl;
  }

  /// 获取 STS 凭证 (带缓存)
  ///
  /// 关键修复 (2026-08-01): 必须传 `appName` query 参数, 否则接口返回
  /// `{"success":false,"code":400,"msg":"appName 不能为空"}`。
  Future<_StsCredentials?> _getStsCredentials({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedSts != null &&
        _cachedStsExpiry != null &&
        DateTime.now().isBefore(_cachedStsExpiry!)) {
      return _cachedSts;
    }

    try {
      final response = await _client.get(
        ApiConstants.cosCredentialsUrl,
        queryParameters: {'appName': appName},
        headers: {
          ...ApiHeaders.web,
        },
      );
      if (!response.isSuccess) return null;
      final data = response.data;
      if (data is! Map<String, dynamic>) return null;

      // 凭证字段嵌套在 data.credentials 下
      final creds = data['credentials'];
      if (creds is! Map<String, dynamic>) return null;

      final accessKeyId = (creds['accessKeyId'] ?? '').toString();
      final accessKeySecret = (creds['accessKeySecret'] ?? '').toString();
      final securityToken = (creds['securityToken'] ?? '').toString();
      final expiration = (creds['expiration'] ?? '').toString();
      if (accessKeyId.isEmpty || accessKeySecret.isEmpty) return null;

      final bucket = (data['bucket'] ?? '').toString();
      final region = (data['region'] ?? '').toString();
      final prefix = (data['prefix'] ?? '').toString();
      final cdnBaseUrl = (data['cdnBaseUrl'] ?? '').toString();
      final endpointHost = (data['endpoint'] ?? '').toString();

      // 派生 endpoint URL (response 的 endpoint 不含协议头)
      String endpoint;
      if (endpointHost.isNotEmpty) {
        endpoint = endpointHost.startsWith('http')
            ? endpointHost
            : 'https://$endpointHost';
      } else if (region.isNotEmpty) {
        endpoint = 'https://$region.aliyuncs.com';
      } else {
        endpoint = 'https://oss-cn-hangzhou.aliyuncs.com';
      }

      // 用接口返回的 expiration (ISO 8601) 计算缓存过期时间,
      // 默认提前 2 分钟刷新 (避免临界过期), 解析失败时回退到 10 分钟
      DateTime? expiryTime;
      if (expiration.isNotEmpty) {
        try {
          expiryTime = DateTime.parse(expiration).toLocal();
        } catch (_) {}
      }
      final cacheExpiry = expiryTime != null
          ? expiryTime.subtract(const Duration(minutes: 2))
          : DateTime.now().add(const Duration(minutes: 10));

      final sts = _StsCredentials(
        accessKeyId: accessKeyId,
        accessKeySecret: accessKeySecret,
        securityToken: securityToken,
        bucket: bucket,
        endpoint: endpoint,
        prefix: prefix,
        cdnBaseUrl: cdnBaseUrl,
        region: region,
        expiration: expiration,
      );
      _cachedSts = sts;
      _cachedStsExpiry = cacheExpiry;
      return sts;
    } catch (_) {
      return null;
    }
  }

  /// 上报文件信息到 /fs/upload/complete
  ///
  /// 对齐 Web 端 reportFileInfo(u, t.size) 调用,
  /// 此步骤非关键 (失败不影响已上传的文件), 仅记录日志。
  Future<void> _reportUploadComplete({
    required String fileUrl,
    required int fileSize,
    required String fileName,
  }) async {
    try {
      await _client.post(
        '/fs/upload/complete',
        data: {
          'fileUrl': fileUrl,
          'fileSize': fileSize,
          'fileName': fileName,
        },
        headers: {
          ...ApiHeaders.web,
        },
      );
    } catch (_) {
      // 非关键步骤, 忽略错误
    }
  }

  /// 构建 OSS V1 签名的 StringToSign
  ///
  /// 格式:
  /// ```
  /// HTTP-Verb\n
  /// Content-MD5\n
  /// Content-Type\n
  /// Date\n
  /// CanonicalizedOSSHeaders\n
  /// CanonicalizedResource
  /// ```
  String _buildStringToSign({
    required String method,
    required String contentMd5,
    required String contentType,
    required String date,
    required String securityToken,
    required String bucket,
    required String objectKey,
  }) {
    // CanonicalizedOSSHeaders (按字典序排列, 以 \n 分隔, 以 \n 结尾)
    //
    // 仅包含实际发送的 x-oss-* header, 必须与 PUT 请求 header 完全一致:
    // - x-oss-object-acl: public-read (对齐 Web 端 EWTFileService.upload)
    // - x-oss-security-token: STS 临时凭证
    // (不包含 x-oss-forbid-overwrite, Web 端未使用)
    final ossHeaders = <String, String>{
      'x-oss-object-acl': 'public-read',
      'x-oss-security-token': securityToken,
    };
    final sortedKeys = ossHeaders.keys.toList()..sort();
    final canonicalOssHeaders =
        sortedKeys.map((k) => '$k:${ossHeaders[k]}').join('\n');

    // CanonicalizedResource
    final canonicalResource = '/$bucket/$objectKey';

    return '$method\n'
        '$contentMd5\n'
        '$contentType\n'
        '$date\n'
        '$canonicalOssHeaders\n'
        '$canonicalResource';
  }

  /// 计算 HMAC-SHA1 并返回 Base64 编码
  String _hmacSha1Base64(String key, String data) {
    final hmac = Hmac(sha1, utf8.encode(key));
    final digest = hmac.convert(utf8.encode(data));
    return base64.encode(digest.bytes);
  }

  /// 计算内容的 MD5 并返回 Base64 编码
  String _base64Md5(Uint8List bytes) {
    final digest = md5.convert(bytes);
    return base64.encode(digest.bytes);
  }
}

/// STS 凭证
class _StsCredentials {
  final String accessKeyId;
  final String accessKeySecret;
  final String securityToken;
  final String bucket;

  /// OSS 区域 endpoint URL (含 https://)
  final String endpoint;

  /// OSS 对象路径前缀 (含尾部 /, 如 `resources/answer-pc/uploads/`)
  final String prefix;

  /// CDN 基础 URL (用于构造最终可访问 URL, 如 `https://cdn.ewt360.com`)
  final String cdnBaseUrl;

  /// OSS 区域 (如 `oss-cn-hangzhou`), 用于日志/诊断
  final String region;

  /// 凭证过期时间 (ISO 8601)
  final String expiration;

  const _StsCredentials({
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.securityToken,
    required this.bucket,
    required this.endpoint,
    required this.prefix,
    required this.cdnBaseUrl,
    required this.region,
    required this.expiration,
  });
}
