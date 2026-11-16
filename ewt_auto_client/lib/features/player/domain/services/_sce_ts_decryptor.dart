/// 阿里云私有加密 HLS 的样本级解密器：TS 容器明文直通，仅对视频/音频 PID 的
/// PES 负载做 AES-128-ECB 原地解密（密钥为 SceCipher.deriveVpk 产出的 _vpk）。
/// 输出与输入等长且结构合法，可直接交给 mpv/ffmpeg 播放或封装。
library;

import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

import '_sce_cipher.dart';

/// 阿里云私有加密 HLS 的**样本级**解密器 (TS 容器直通)
///
/// ## 为什么不是整段 AES-128
///
/// 加密 m3u8 里的 `#EXT-X-KEY:MEATHOD=AES-128,URI="<base64块>"` 是个**陷阱**:
/// `MEATHOD` 是阿里云的拼写错误, 标准播放器 (hls.js/mpv/ffmpeg) 解析不到
/// `METHOD=`, 会按"未加密"处理; 而站点自己的 `ali-hls` 则完全忽略这一行,
/// 改在 **TS demux 阶段**对每个 PES 负载做 AES-128-**ECB** 解密
/// (见 `ali-hls.min.1.1.2.js` 中 `q(pes, this.config._vpk)`)。
///
/// 所以真实结构是:
///   - TS 容器 (188 字节包头/同步字节 0x47/PAT/PMT) **完全明文**;
///   - 视频 PID (0xE0) 与音频 PID (0xC0) 的 **PES 负载**被 AES-128-ECB 加密,
///     密钥即 [SceCipher.deriveVpk] 产出的 16 字节 `_vpk`。
///
/// ## 本实现
///
/// ECB 解密不改变字节长度, 因此只需**原地替换**各 TS 包中属于 PES 负载的
/// 字节, 无需重新分片/重算 PCR —— 输出仍是与输入等长且结构合法的 MPEG-TS,
/// 可直接拼接后交给 ffmpeg 封装, 也能被 mpv/ffprobe 直接识别。
///
/// 16 字节分组的对齐是**跨 TS 包连续**的 (对齐 ali-hls 先拼接再解密的行为),
/// 而 TS 包边界并不总是 16 的倍数, 因此按 PID 归集后统一处理。
class SceTsSampleDecryptor {
  SceTsSampleDecryptor._();

  /// TS 包尺寸
  static const int tsPacketSize = 188;

  /// TS 同步字节
  static const int tsSyncByte = 0x47;

  /// 将加密 TS 就地转换为明文 TS
  ///
  /// [ts] 原始分片字节 (长度应为 188 的倍数, 非严格);
  /// [key] [SceCipher.deriveVpk] 产出的 16 字节密钥;
  /// 返回与输入**等长**的解密字节 (无法解密的部分原样保留)。
  static Uint8List decryptTs(Uint8List ts, Uint8List key) {
    final out = Uint8List.fromList(ts);
    if (ts.length < tsPacketSize || key.isEmpty) return out;

    // ── 第一遍: 按 PID 归集所有含负载的段 ──
    final byPid = <int, List<_PayloadSpan>>{};
    for (var off = 0; off + tsPacketSize <= ts.length; off += tsPacketSize) {
      if (ts[off] != tsSyncByte) continue;
      final pusi = (ts[off + 1] & 0x40) != 0;
      final pid = ((ts[off + 1] & 0x1f) << 8) | ts[off + 2];
      final hasAdapt = (ts[off + 3] & 0x20) != 0;
      final hasPayload = (ts[off + 3] & 0x10) != 0;
      if (!hasPayload) continue;
      var start = off + 4;
      if (hasAdapt) {
        start += ts[off + 4] + 1; // adaptation_field_length + 1
        if (start > off + tsPacketSize) continue;
      }
      (byPid[pid] ??= <_PayloadSpan>[]).add(_PayloadSpan(
        packetStart: off,
        payloadStart: start,
        payloadEnd: off + tsPacketSize,
        startsPes: pusi,
      ));
    }

    final encrypter = enc.Encrypter(enc.AES(
      enc.Key(key),
      mode: enc.AESMode.ecb,
      padding: null,
    ));

    // ── 第二遍: 逐 PID 切出 PES, 解密后写回 ──
    for (final spans in byPid.values) {
      // 只处理 PES 流 (音视频); PAT/PMT/其它表不解密
      if (!_looksLikePesStream(ts, spans)) continue;

      var i = 0;
      while (i < spans.length) {
        // 定位一个 PES 包的起始段
        if (!spans[i].startsPes) {
          i++;
          continue;
        }
        // 收集该 PES 的所有数据段, 并跳过 PES 头
        final head = _parsePesHeader(ts, spans[i]);
        var headerRemaining = head.headerLen;
        var dataRemaining = head.dataLen; // null = PES_packet_length 未给出
        final group = <_DataRange>[];
        var j = i;
        while (j < spans.length) {
          final s = spans[j];
          var from = s.payloadStart;
          var to = s.payloadEnd;
          if (headerRemaining > 0) {
            final skip = headerRemaining < (to - from) ? headerRemaining : (to - from);
            from += skip;
            headerRemaining -= skip;
          }
          if (dataRemaining != null) {
            final take = dataRemaining < (to - from) ? dataRemaining : (to - from);
            to = from + take;
            dataRemaining -= take;
          }
          if (to > from) group.add(_DataRange(from, to));
          j++;
          if (dataRemaining != null && dataRemaining <= 0) break;
          if (j < spans.length && spans[j].startsPes) break; // 下一个 PES
        }
        if (group.isEmpty) {
          i = j > i ? j : i + 1;
          continue;
        }

        // 拼接 → 解密前 floor(len/16)*16 字节 → 写回
        final total = group.fold<int>(0, (sum, r) => sum + (r.end - r.start));
        final aligned = (total ~/ 16) * 16;
        if (aligned > 0) {
          final buf = Uint8List(aligned);
          var w = 0;
          for (final r in group) {
            final n = r.end - r.start;
            if (w >= aligned) break;
            final take = n < (aligned - w) ? n : (aligned - w);
            buf.setRange(w, w + take, ts.sublist(r.start, r.start + take));
            w += take;
          }
          final plain = Uint8List.fromList(
            encrypter.decryptBytes(enc.Encrypted(buf)),
          );
          // 写回
          var r2 = 0;
          for (final r in group) {
            if (r2 >= aligned) break;
            final n = r.end - r.start;
            final take = n < (aligned - r2) ? n : (aligned - r2);
            out.setRange(r.start, r.start + take, plain.sublist(r2, r2 + take));
            r2 += take;
          }
        }
        i = j;
      }
    }
    return out;
  }

  /// 解析 PES 头
  ///
  /// - [headerLen] = 9 + PES_header_data_length (6 字节前缀 + 3 字节基本头 + 可选头)
  /// - [dataLen] = PES_packet_length - 3 - PES_header_data_length;
  ///   PES_packet_length 为 0 (仅视频流允许, 表示"任意长度") 时返回 null
  static _PesHead _parsePesHeader(Uint8List ts, _PayloadSpan span) {
    final len = span.payloadEnd - span.payloadStart;
    if (len < 9) return _PesHead(len, null);
    final p = span.payloadStart;
    if (ts[p] != 0 || ts[p + 1] != 0 || ts[p + 2] != 1) {
      return _PesHead(0, null); // 不是 PES (例如 PSI 表)
    }
    final packetLen = (ts[p + 4] << 8) + ts[p + 5];
    final hdl = ts[p + 8];
    var headerLen = 9 + hdl;
    if (headerLen > len) headerLen = len;
    final dataLen = packetLen > 3 + hdl ? packetLen - 3 - hdl : null;
    return _PesHead(headerLen, dataLen);
  }

  /// 该 PID 是否为 PES 流 (以 00 00 01 + 音视频 stream_id 开头)
  static bool _looksLikePesStream(Uint8List ts, List<_PayloadSpan> spans) {
    for (final s in spans) {
      if (!s.startsPes) continue;
      final len = s.payloadEnd - s.payloadStart;
      if (len < 4) continue;
      if (ts[s.payloadStart] != 0 ||
          ts[s.payloadStart + 1] != 0 ||
          ts[s.payloadStart + 2] != 1) {
        return false;
      }
      final sid = ts[s.payloadStart + 3];
      // 0xE0..0xEF 视频, 0xC0..0xDF 音频
      return (sid >= 0xe0 && sid <= 0xef) || (sid >= 0xc0 && sid <= 0xdf);
    }
    return false;
  }

  /// 便捷: 用 [SceCipher.deriveVpk] 的结果直接解密已缓存的 TS 字节
  static Uint8List decryptTsWithVpk(Uint8List ts, Uint8List vpk) =>
      decryptTs(ts, vpk);
}

/// 一个 TS 包内的负载区间
class _PayloadSpan {
  final int packetStart;
  final int payloadStart;
  final int payloadEnd;
  final bool startsPes;

  const _PayloadSpan({
    required this.packetStart,
    required this.payloadStart,
    required this.payloadEnd,
    required this.startsPes,
  });
}

/// 属于某个 PES 负载的连续字节区间 (绝对偏移)
class _DataRange {
  final int start;
  final int end;

  const _DataRange(this.start, this.end);
}

/// PES 头解析结果
class _PesHead {
  /// 头总长度 (含可选头)
  final int headerLen;

  /// 负载数据长度; null 表示 PES_packet_length 未给出 (按到下一个 PES 为止)
  final int? dataLen;

  const _PesHead(this.headerLen, this.dataLen);
}
