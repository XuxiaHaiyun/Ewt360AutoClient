/// 视频源解析器单元测试 (离线, 不触发网络)
///
/// 覆盖 [VideoSourceResolver] 的无网络路径与工具方法:
///   - 空 videoList 快速返回 null
///   - [ResolvedVideoSource] 格式判断 / toString 安全截断
///   - [VideoSourceResolver.appendToken] URL token 追加
///   - [VideoSourceResolver.dlHeaders] 下载请求头 (Origin=teacher.ewt360.com)
library;

import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/player/domain/services/video_source_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fixtures.dart';

void main() {
  late VideoSourceResolver resolver;
  late EndpointConfig endpointConfig;

  setUp(() {
    endpointConfig = EndpointConfig.defaults();
    final client = DioClient(endpointConfig: endpointConfig);
    resolver = VideoSourceResolver(client: client);
  });

  group('ResolvedVideoSource', () {
    test('isM3u8: URL 含 m3u8 或 format=m3u8', () {
      const fromUrl = ResolvedVideoSource(
        url: 'https://x.com/a.m3u8?token=1',
        drmToken: 't',
      );
      expect(fromUrl.isM3u8, isTrue);

      const fromFormat = ResolvedVideoSource(
        url: 'https://x.com/video',
        format: 'm3u8',
      );
      expect(fromFormat.isM3u8, isTrue);

      const mp4 = ResolvedVideoSource(url: 'https://x.com/a.mp4');
      expect(mp4.isM3u8, isFalse);
    });

    test('toString 长 URL 截断, drmToken 显示长度', () {
      final longUrl = 'https://example.com/${'x' * 200}';
      final src = ResolvedVideoSource(url: longUrl, drmToken: '123456');
      final s = src.toString();
      expect(s, isNot(contains('123456')), reason: '不应泄露完整 drmToken');
      expect(s, anyOf(contains('m3u8'), contains('mp4')));
      expect(s.length, lessThan(180));
    });
  });

  group('VideoSourceResolver.resolve (无网络路径)', () {
    test('空 videoList 返回 null (不触发任何网络请求)', () async {
      final result = await resolver.resolve(buildEmptyVideoInfo());
      expect(result, isNull);
    });
  });

  group('VideoSourceResolver.appendToken', () {
    test('无 token 时原样返回', () {
      expect(VideoSourceResolver.appendToken('https://x.com/a', ''), 'https://x.com/a');
    });

    test('追加 token 参数 (URL 编码)', () {
      final out = VideoSourceResolver.appendToken('https://x.com/a', 'abc def');
      expect(out, 'https://x.com/a?token=abc%20def');
    });

    test('已有 ? 查询参数时用 & 连接', () {
      final out = VideoSourceResolver.appendToken('https://x.com/a?b=1', 't');
      expect(out, 'https://x.com/a?b=1&token=t');
    });

    test('已含 token= 时不重复追加', () {
      final out = VideoSourceResolver.appendToken('https://x.com/a?token=old', 'new');
      expect(out, 'https://x.com/a?token=old');
    });
  });

  group('VideoSourceResolver.dlHeaders', () {
    test('Origin/Referer 使用 teacher.ewt360.com (HLS CDN 校验)', () {
      final headers = resolver.dlHeaders;
      expect(headers['Origin'], 'https://teacher.ewt360.com');
      expect(headers['Referer'], 'https://teacher.ewt360.com/');
    });

    test('UA 继承端点配置的浏览器 UA', () {
      expect(resolver.dlHeaders['User-Agent'], endpointConfig.userAgent);
    });

    test('携带端点额外 headers', () {
      final headers = resolver.dlHeaders;
      for (final entry in endpointConfig.extraHeaders.entries) {
        expect(headers[entry.key], entry.value);
      }
    });
  });

  group('清晰度档位构建 (纯函数)', () {
    test('腾讯云 drmOutput: definition 数值映射中文标签, 首项默认', () {
      final qualities = VideoSourceResolver.tencentQualitiesFrom([
        {'url': 'https://x.com/od.m3u8', 'definition': 0},
        {'url': 'https://x.com/20.m3u8', 'definition': 20},
        {'url': 'https://x.com/30.m3u8', 'definition': 30},
      ]);
      expect(qualities.map((q) => q.label).toList(), ['原画', '标清', '高清']);
      expect(qualities.first.url, 'https://x.com/od.m3u8');
    });

    test('腾讯云: height 优先于 definition, 空 URL/非法条目跳过, 未知定义回退档位N', () {
      final qualities = VideoSourceResolver.tencentQualitiesFrom([
        {'url': 'a.m3u8', 'height': 1080, 'definition': 0},
        {'url': ''},
        {'url': 'b.m3u8', 'definition': 'weird'},
        'not-a-map',
      ]);
      expect(qualities.map((q) => q.label).toList(), ['1080P', '档位2']);
      expect(qualities.last.url, 'b.m3u8');
    });

    test('阿里云 MP4: Definition 命名映射 (FD/OD/LD), 保留排序', () {
      final qualities = VideoSourceResolver.aliyunQualitiesFrom([
        {'PlayURL': 'https://x.com/fd.mp4', 'Definition': 'FD'},
        {'PlayURL': 'https://x.com/od.mp4', 'Definition': 'OD'},
        {'PlayURL': 'https://x.com/ld.mp4', 'Definition': 'LD'},
      ]);
      expect(qualities.map((q) => q.label).toList(), ['全高清', '原画', '流畅']);
      expect(qualities.first.url, 'https://x.com/fd.mp4');
    });

    test('阿里云: Height 优先, 空 URL 跳过, 未知定义回退档位N', () {
      final qualities = VideoSourceResolver.aliyunQualitiesFrom([
        {'PlayURL': 'a.mp4', 'Height': 720, 'Definition': 'FD'},
        {'PlayURL': ''},
        {'PlayURL': 'b.mp4', 'Definition': 'unknown-def'},
      ]);
      expect(qualities.map((q) => q.label).toList(), ['720P', '档位2']);
    });

    test('ResolvedVideoSource 默认 qualities 为空 (不显示切换按钮)', () {
      const src = ResolvedVideoSource(url: 'https://x.com/a.mp4');
      expect(src.qualities, isEmpty);
    });

    test('aliyunQualitiesFrom: 私有加密档位携带 Plaintext 密钥', () {
      final qualities = VideoSourceResolver.aliyunQualitiesFrom([
        {
          'PlayURL': 'https://vod01.ewt360.com/a/sd-encrypt-stream.m3u8',
          'Definition': 'SD',
          'Format': 'm3u8',
          'Height': 720,
          'Encrypt': 1,
          'EncryptType': 'AliyunVoDEncryption',
          'Plaintext': '8JJuYAkLYP/9YT8L/igilpyS3Q2M+pBOwUZi3SnweIg=',
        },
        {
          'PlayURL': 'https://vod01.ewt360.com/a/ld-encrypt-stream.m3u8',
          'Definition': 'LD',
          'Format': 'm3u8',
          'Height': 540,
          'Encrypt': 1,
          'EncryptType': 'AliyunVoDEncryption',
          'Plaintext': 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4',
        },
      ]);
      expect(qualities.map((q) => q.label).toList(), ['720P', '540P']);
      expect(qualities[0].keyBase64, '8JJuYAkLYP/9YT8L/igilpyS3Q2M+pBOwUZi3SnweIg=');
      expect(qualities[1].keyBase64, isNotNull);
    });

    test('stripHlsKey: 丢弃私有加密的诱饵 KEY 行 + 相对分片绝对化', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-KEY:MEATHOD=AES-128,URI="MTM4ZDkxZGMtYjZiZS00YzFlLWI0MTItZjk2NzA3"\n'
          '#EXTINF:10.000000,\n'
          'seg-00001.ts';
      final out = VideoSourceResolver.stripHlsKey(
        playlist: playlist,
        baseUrl: 'https://vod01.ewt360.com/a/b/c.m3u8',
      );
      expect(out, isNot(contains('EXT-X-KEY')));
      expect(out, isNot(contains('MTM4ZDkx')));
      expect(out, contains('https://vod01.ewt360.com/a/b/seg-00001.ts'));
      expect(out, contains('#EXTM3U'));
    });

    test('rewriteHlsKey: 修正 MEATHOD 拼写 + 替换密钥 URI + 相对分片绝对化', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-KEY:MEATHOD=AES-128,URI="MTM4ZDkxZGMtYjZiZS00YzFlLWI0MTItZjk2NzA3YjBiYTMx"\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n'
          '#EXTINF:10.000000,\n'
          'seg-00001.ts\n'
          '#EXTINF:10.000000,\n'
          'seg-00002.ts';
      final out = VideoSourceResolver.rewriteHlsKey(
        playlist: playlist,
        keyUri: 'data:application/octet-stream;base64,QUJDRA==',
        baseUrl: 'https://vod01.ewt360.com/a/b/c.m3u8',
      );
      expect(out, contains('METHOD=AES-128'));
      expect(out, isNot(contains('MEATHOD')));
      expect(out, contains('URI="data:application/octet-stream;base64,QUJDRA=="'));
      expect(out, contains('https://vod01.ewt360.com/a/b/seg-00001.ts'));
      expect(out, contains('https://vod01.ewt360.com/a/b/seg-00002.ts'));
    });
  });
}
