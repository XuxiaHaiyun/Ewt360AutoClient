// 临时诊断: 阿里云线路 + 私有加密 (_sce_*) 全链路验证 (真实登录, 不提交)
//
// 用测试账号登录 → getPlayerToken → getExternalVideoInfo(91251) →
// 打印 videoList/definitionList 结构 → 跑 VideoSourceResolver (aliyun) 带日志
// → 对每个私有加密档位用派生出的 AES 密钥实际解密第一个 TS 分片,
//   校验 MPEG-TS 同步字节 0x47。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio_pkg;
import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:ewt_auto_client/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:ewt_auto_client/features/player/data/datasources/player_remote_datasource.dart';
import 'package:ewt_auto_client/features/player/domain/services/_sce_cipher.dart';
import 'package:ewt_auto_client/features/player/domain/services/aliyun_hls_proxy.dart';
import 'package:ewt_auto_client/features/player/domain/services/_sce_ts_decryptor.dart';
import 'package:ewt_auto_client/features/player/domain/services/video_source_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('aliyun line diagnosis', () async {
    // 账号经环境变量注入 (避免凭据入库):
    //   EWT_TEST_ACCOUNT / EWT_TEST_PASSWORD
    // 也可将 token+userId+schoolId 写入 test/accounts.json 复用 TestHarness。
    final account = Platform.environment['EWT_TEST_ACCOUNT'];
    final password = Platform.environment['EWT_TEST_PASSWORD'];
    if (account == null || password == null || account.isEmpty) {
      stdout.writeln('跳过: 未设置 EWT_TEST_ACCOUNT / EWT_TEST_PASSWORD');
      return;
    }
    final endpointConfig = EndpointConfig.defaults();
    final client = DioClient(endpointConfig: endpointConfig);
    final auth = AuthRepositoryImpl(
      AuthRemoteDataSource(client),
      client,
    );

    final session = await auth.loginWithPassword(
      account: account,
      password: password,
    );
    stdout.writeln('登录成功: userId=${session.userId} schoolId=${session.schoolId}');

    final playerRemote = PlayerRemoteDataSource(client);
    final schoolId = session.schoolId;

    String videoToken = '';
    try {
      videoToken = await playerRemote.getPlayerToken(
        schoolId: schoolId,
        lessonId: '91251',
      );
      stdout.writeln('getPlayerToken: ${videoToken.isEmpty ? "<空>" : "ok (${videoToken.length}字符)"}');
    } catch (e) {
      stdout.writeln('getPlayerToken 失败: $e');
    }

    final info = await playerRemote.getExternalVideoInfo(
      lessonId: '91251',
      videoToken: videoToken,
    );
    stdout.writeln('videoInfo keys: ${info.keys.toList()}');
    final vl = (info['videoList'] as List?) ?? [];
    stdout.writeln('videoList: ${vl.length} 个');
    for (var i = 0; i < vl.length; i++) {
      final v = vl[i] as Map;
      stdout.writeln(
          '[$i] showPlat=${v['showPlat']} videoId=${v['videoId']} platFormUuId=${v['platFormUuId']}');
      final dl = (v['definitionList'] as List?) ?? [];
      for (var j = 0; j < dl.length; j++) {
        final d = dl[j] as Map;
        final psign = (d['psign'] ?? '').toString();
        final Map<String, dynamic>? decoded = () {
          try {
            final normalized = base64.normalize(psign);
            final bytes = base64.decode(normalized);
            final txt = utf8.decode(bytes);
            final parsed = jsonDecode(txt);
            return parsed is Map<String, dynamic> ? parsed : null;
          } catch (_) {
            return null;
          }
        }();
        stdout.writeln(
            '  def[$j] ${jsonEncode({for (final e in d.entries) if (e.key != 'psign') e.key: e.value})} '
            'psign=${psign.length}字符 type=${decoded != null ? "STS-JSON(aks=${(decoded['AccessKeyId'] ?? '').toString().length})" : "非STS(前16=${psign.substring(0, psign.length > 16 ? 16 : psign.length)}...)"}');
        if (decoded != null) {
          stdout.writeln('    psign字段: ${decoded.keys.toList()}');
          final ai = decoded['AuthInfo'];
          if (ai != null) {
            stdout.writeln('    AuthInfo字段: ${(jsonDecode(ai.toString()) as Map).keys.toList()}');
          }
        }
      }
    }

    // 跑解析器 (aliyun), 打开日志
    final resolver = VideoSourceResolver(client: client, onLog: (m, {warning = false}) {
      stdout.writeln('[resolver${warning ? '!' : ''}] $m');
    });
    final src = await resolver.resolve(info, line: VideoLine.aliyun);
    stdout.writeln('aliyun 结果: ${src == null ? "null" : "format=${src.format} key=${src.keyBase64 != null}"}');
    if (src != null) {
      stdout.writeln('aliyun 完整URL: ${src.url}');
      for (final q in src.qualities) {
        stdout.writeln(
            '  档位 ${q.label}: ${q.url} key=${q.keyBase64 == null ? "无" : "有(${q.keyBase64!.length}字符)"}');
      }
    }

    // ── 私有加密全链路验证: 派生密钥能否真正解开 TS 分片 ──
    //
    // 站点 _sce_* 链已在 lib/features/player/domain/services/_sce_cipher.dart
    // 复刻; 这里用真实服务端素材跑一遍最硬的验收: 解出第一段 TS 并检查
    // MPEG-TS 同步字节 0x47 (解错时首字节必然是随机数)。
    final rawDio = dio_pkg.Dio(dio_pkg.BaseOptions(
      responseType: dio_pkg.ResponseType.bytes,
      validateStatus: (_) => true,
    ));
    final dlHeaders = resolver.dlHeaders;

    Future<List<int>?> getBytes(String url) async {
      try {
        final r = await rawDio.get<List<int>>(url,
            options: dio_pkg.Options(headers: dlHeaders));
        if (r.statusCode != null && r.statusCode! >= 400) return null;
        return r.data;
      } catch (_) {
        return null;
      }
    }

    // 逐个清晰度验证 (只要有派生密钥的档都验一遍)
    final targets = <ResolvedVideoQuality>[];
    if (src != null) targets.addAll(src.qualities);

    for (final q in targets) {
      final key = q.keyBase64;
      if (key == null) {
        stdout.writeln('档位 ${q.label}: 无密钥 (非加密流), 跳过 TS 校验');
        continue;
      }
      final keyBytes = base64.decode(key);
      stdout.writeln(
          '档位 ${q.label}: 派生密钥 ${keyBytes.length} 字节 b64=${key.length}字符');

      final m3u8Bytes = await getBytes(q.url);
      if (m3u8Bytes == null) {
        stdout.writeln('  拉取 m3u8 失败');
        continue;
      }
      final playlist = utf8.decode(m3u8Bytes);
      final keyLine = playlist
          .split('\n')
          .firstWhere((l) => l.trim().startsWith('#EXT-X-KEY'),
              orElse: () => '<无>')
          .trim();
      stdout.writeln('  EXT-X-KEY 全文: $keyLine');

      // 落盘供离线分析 (debug/video/)
      _dumpArtifact('live_${q.label}.m3u8', playlist);
      _dumpArtifact('live_${q.label}.key', key);

      // 重写播放列表: 修正 MEATHOD → METHOD, 并把密钥块换成 data: URI
      final rewritten = VideoSourceResolver.rewriteHlsKey(
        playlist: playlist,
        keyUri: 'data:application/octet-stream;base64,$key',
        baseUrl: q.url,
      );
      final firstKey = rewritten
          .split('\n')
          .firstWhere((l) => l.trim().startsWith('#EXT-X-KEY'), orElse: () => '');
      if (!firstKey.contains('METHOD=') || firstKey.contains('MEATHOD')) {
        stdout.writeln('  [FAIL] rewriteHlsKey 未产出标准 KEY 行');
        continue;
      }

      // 取第一个分片做 AES-128-CBC 解密自测 (无 IV 属性时 IV = 序列号 0)
      final segLine = rewritten.split('\n').firstWhere(
          (l) => l.trim().isNotEmpty && !l.trim().startsWith('#'),
          orElse: () => '');
      if (segLine.isEmpty) {
        stdout.writeln('  [FAIL] 播放列表无分片');
        continue;
      }
      final segBytes = await getBytes(segLine.trim());
      if (segBytes == null || segBytes.isEmpty) {
        stdout.writeln('  [FAIL] 拉取分片失败');
        continue;
      }
      // ── 私有加密 = 样本级加密 ──
      //
      // TS 容器是明文 (0x47 同步字节), 被加密的是每个 PES 负载 (AES-128-ECB,
      // 密钥 _vpk)。整段做 AES-CBC 是对不上的 —— 站点 ali-hls 就在 demux
      // 阶段用 config._vpk 解每个 PES。因此这里验两件事:
      //   1) 原始分片首字节就是 0x47 (容器未加密);
      //   2) 经 SceTsSampleDecryptor 后, 视频 PES 出现 00 00 01 NAL 起始码。
      final containerClear = segBytes.isNotEmpty && segBytes[0] == 0x47;
      final decrypted = SceTsSampleDecryptor.decryptTs(
        Uint8List.fromList(segBytes),
        Uint8List.fromList(keyBytes),
      );
      _dumpArtifactBytes('seg_${q.label}_plain.ts', decrypted);

      final nal = _findFirstStartCode(decrypted);
      final okSample = nal >= 0;
      stdout.writeln(
          '  样本级解密: 容器首字节 0x'
          '${segBytes.isEmpty ? "-" : segBytes[0].toRadixString(16).padLeft(2, "0")}'
          ' (${containerClear ? "明文 TS" : "整段被加密"})'
          ', 解密后首个 000001 起始码 @$nal'
          '${nal >= 0 && nal + 3 < decrypted.length ? " nal_type=0x${(decrypted[nal + 3] & 0x1f).toRadixString(16)}" : ""}'
          ' → ${okSample && containerClear ? "OK" : "FAIL"}');
    }

    // ── 本地解密代理端到端验证 ──
    //
    // AliyunHlsProxy 在 127.0.0.1 上伪装成普通 HLS 源: mpv 播放它时, 代理
    // 按需拉段 → 样本级解密 → 回吐明文 TS。这里用 HTTP 客户端模拟 mpv:
    // 拉代理的 playlist, 再拉一个分片, 校验它确实是明文 TS (含 NAL 起始码)。
    if (src != null && src.aliyunEncrypted) {
      try {
        final proxy = await AliyunHlsProxy.start(
          qualities: src.qualities,
          headers: resolver.dlHeaders,
        );
        stdout.writeln('代理已启动: ${proxy.playlistUrl}');

        final http = HttpClient();
        Future<List<int>> getLocal(String url) async {
          final req = await http.getUrl(Uri.parse(url));
          final resp = await req.close();
          final out = <int>[];
          await for (final chunk in resp) {
            out.addAll(chunk);
          }
          return out;
        }

        final plBytes = await getLocal(proxy.playlistUrl);
        final plText = utf8.decode(plBytes);
        stdout.writeln('  代理 playlist ${plBytes.length} 字节, 含 EXT-X-KEY: '
            '${plText.contains('EXT-X-KEY')} (应为 false)');
        stdout.writeln('  代理 playlist 首 3 行: '
            '${plText.split('\n').take(3).join(' | ')}');

        final segLine = plText
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'),
                orElse: () => '');
        if (segLine.isNotEmpty) {
          final seg = Uint8List.fromList(await getLocal(segLine));
          final nal = _findFirstStartCode(seg);
          final nalType = (nal >= 0 && nal + 3 < seg.length)
              ? (seg[nal + 3] & 0x1f).toRadixString(16)
              : '-';
          stdout.writeln('  代理分片: $segLine');
          stdout.writeln('    ${seg.length} 字节, 首字节 0x'
              '${seg.isEmpty ? "-" : seg[0].toRadixString(16).padLeft(2, "0")}'
              ', 首个 000001 起始码 @$nal nal_type=0x$nalType'
              ' → ${seg.isNotEmpty && seg[0] == 0x47 && nal >= 0 ? "OK (明文 TS)" : "FAIL"}');
        } else {
          stdout.writeln('  [FAIL] 代理 playlist 无分片');
        }
        http.close();
        await proxy.stop();
        stdout.writeln('  代理已停止');
      } catch (e) {
        stdout.writeln('  [FAIL] 代理验证异常: $e');
      }
    }

    // 站点 oracle 固定向量复核 (确认本地实现未被改动破坏)
    final vecOk = <bool>[];
    for (final v in _oracleVectors) {
      vecOk.add(
        SceCipher.deriveVpkBase64(
              secret: v.$1,
              rand: v.$2,
              plaintext: v.$3,
            ) ==
            v.$4,
      );
    }
    stdout.writeln(
        '站点固定向量复核: ${vecOk.where((e) => e).length}/${vecOk.length} 通过');

    // 对照: auto
    final srcAuto = await resolver.resolve(info, line: VideoLine.auto);
    stdout.writeln('auto 结果: ${srcAuto == null ? "null" : "line=${srcAuto.line} format=${srcAuto.format}"}');

    client.token = null;
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// (secret, 响应Rand, Plaintext, 期望密钥base64) — 取自站点 bundle 实测输出
const _oracleVectors = <(String, String, String, String)>[
  (
    'TKa0BYk5eSw3kbY2',
    'PvnIM6oB496oxQ+veIon1Q==',
    'UrQqsyHgWC/pnFHU8PXPV0MUBwvOAcuBQ0nOj3+Ic5g=',
    'VbqCl3X40qLmTnJP1eXrPA=='
  ),
  (
    'ZJiQERRb6N7JK63Y',
    'zdoHwsuXcSTFgObMUJpHswv7Ukb07zPx1nI8LCUMDVI=',
    'mcqN2uLtNfeJ8Hj7OqgMSNjqnVCXDh9DdRc/8lTMPVw=',
    'AAAAAAAAAAAAAAAAAAAAAA=='
  ),
];

/// 在解密后的 TS 中查找第一个 00 00 01 起始码 (Annex-B NAL / ADTS)
int _findFirstStartCode(Uint8List ts) {
  for (var i = 0; i + 2 < ts.length; i++) {
    if (ts[i] == 0 && ts[i + 1] == 0 && ts[i + 2] == 1) return i;
  }
  return -1;
}

/// 落盘中间产物到 debug/video/ (便于离线用 Node/python 复核)
void _dumpArtifact(String name, String content) {
  try {
    const dir = r'C:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\debug\video';
    File('$dir/$name').writeAsStringSync(content);
  } catch (_) {}
}

/// 落盘二进制中间产物 (解密后的 TS, 可直接 ffprobe)
void _dumpArtifactBytes(String name, Uint8List bytes) {
  try {
    const dir = r'C:\Users\Administrator\AndroidStudioProjects\EwtAutoClient\debug\video';
    File('$dir/$name').writeAsBytesSync(bytes);
  } catch (_) {}
}

