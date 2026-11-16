// 阿里云私有加密: 本地透明解密代理的 m3u8 重写逻辑 — 离线单测
import 'package:ewt_auto_client/features/player/domain/services/aliyun_hls_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

const _playlist = '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-ALLOW-CACHE:YES\n'
    '#EXT-X-TARGETDURATION:10\n'
    '#EXT-X-KEY:MEATHOD=AES-128,URI="MTM4ZDkxZGMtYjZiZS00YzFlLWI0MTItZjk2NzA3"\n'
    '#EXT-X-MEDIA-SEQUENCE:0\n'
    '#EXTINF:10.000000,\n'
    'a-sd-encrypt-stream-00001.ts\n'
    '#EXTINF:10.000000,\n'
    'a-sd-encrypt-stream-00002.ts\n'
    '#EXT-X-ENDLIST';

const _base = 'https://vod01.ewt360.com/vid/xxx-sd-encrypt-stream.m3u8';

void main() {
  group('AliyunHlsProxy.rewritePlaylist', () {
    test('分片序号连续, 且被指向代理前缀', () {
      final r = AliyunHlsProxy.rewritePlaylist(
        playlist: _playlist,
        baseUrl: _base,
        proxyPrefix: 'http://127.0.0.1:8081/0',
      );
      expect(r.playlist, contains('http://127.0.0.1:8081/0/seg/0.ts'));
      expect(r.playlist, contains('http://127.0.0.1:8081/0/seg/1.ts'));
      expect(r.playlist, isNot(contains('seg/2.ts')));
    });

    test('删除诱饵 EXT-X-KEY 行', () {
      final r = AliyunHlsProxy.rewritePlaylist(
        playlist: _playlist,
        baseUrl: _base,
        proxyPrefix: 'http://127.0.0.1:8081/0',
      );
      expect(r.playlist, isNot(contains('EXT-X-KEY')));
      expect(r.playlist, isNot(contains('MEATHOD')));
      expect(r.playlist, isNot(contains('MTM4ZDkx')));
    });

    test('segments 为原始绝对 URL, 顺序与序号对应', () {
      final r = AliyunHlsProxy.rewritePlaylist(
        playlist: _playlist,
        baseUrl: _base,
        proxyPrefix: 'http://127.0.0.1:8081/0',
      );
      expect(r.segments, [
        'https://vod01.ewt360.com/vid/a-sd-encrypt-stream-00001.ts',
        'https://vod01.ewt360.com/vid/a-sd-encrypt-stream-00002.ts',
      ]);
    });

    test('保留其它标签行与 ENDLIST', () {
      final r = AliyunHlsProxy.rewritePlaylist(
        playlist: _playlist,
        baseUrl: _base,
        proxyPrefix: 'http://127.0.0.1:8081/0',
      );
      expect(r.playlist, contains('#EXTM3U'));
      expect(r.playlist, contains('#EXT-X-VERSION:3'));
      expect(r.playlist, contains('#EXT-X-MEDIA-SEQUENCE:0'));
      expect(r.playlist, contains('#EXT-X-ENDLIST'));
      expect(r.playlist, contains('#EXTINF:10.000000,'));
    });

    test('分片已是绝对 URL 时不再拼接 base', () {
      const abs = '#EXTM3U\nhttps://cdn.example.com/x/seg-1.ts\n';
      final r = AliyunHlsProxy.rewritePlaylist(
        playlist: abs,
        baseUrl: _base,
        proxyPrefix: 'http://127.0.0.1:1/0',
      );
      expect(r.segments, ['https://cdn.example.com/x/seg-1.ts']);
    });

    test('空播放列表 → 空 segments, 不抛异常', () {
      final r = AliyunHlsProxy.rewritePlaylist(
        playlist: '',
        baseUrl: _base,
        proxyPrefix: 'http://127.0.0.1:1/0',
      );
      expect(r.segments, isEmpty);
    });
  });
}
