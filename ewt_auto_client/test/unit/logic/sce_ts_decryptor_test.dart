// 阿里云私有加密: TS 样本级 (PES 负载 AES-128-ECB) 解密 — 离线单测
//
// 站点行为依据 ali-hls.min.1.1.2.js 中 `q(pes, this.config._vpk)`:
// TS 容器明文, 每个 PES 负载用 _vpk 做 AES-128-ECB 解密;
// 长度非 16 倍数时只解前 floor(len/16)*16 字节, 尾部保持密文。
import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:ewt_auto_client/features/player/domain/services/_sce_cipher.dart';
import 'package:ewt_auto_client/features/player/domain/services/_sce_ts_decryptor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 已知密钥 (与 sce_cipher_test 的向量一致)
const _keyB64 = 'VbqCl3X40qLmTnJP1eXrPA==';

/// 构造一个最小 MPEG-TS: 单个 PID, 一条 PES, 负载为 [payload]
Uint8List _buildTs({
  required int pid,
  required Uint8List pesPayload,
  int streamId = 0xe0,
  int payloadChunk = 184,
}) {
  // PES: 00 00 01 <sid> <len_h> <len_l> 80 00 00 (hdr_data_len=0)
  final packetLen = 3 + pesPayload.length; // 3 字节基本头 + 负载
  final pes = Uint8List.fromList(<int>[
    0x00,
    0x00,
    0x01,
    streamId,
    (packetLen >> 8) & 0xff,
    packetLen & 0xff,
    0x80,
    0x00,
    0x00,
    ...pesPayload,
  ]);

  final packets = <int>[];
  var offset = 0;
  var first = true;
  while (offset < pes.length) {
    final take = (pes.length - offset) < payloadChunk
        ? pes.length - offset
        : payloadChunk;
    final packet = Uint8List(188);
    packet[0] = 0x47;
    packet[1] = (first ? 0x40 : 0x00) | ((pid >> 8) & 0x1f);
    packet[2] = pid & 0xff;
    packet[3] = 0x10; // 仅负载, 无 adaptation
    packet.setRange(4, 4 + take, pes.sublist(offset, offset + take));
    packets.addAll(packet);
    offset += take;
    first = false;
  }
  return Uint8List.fromList(packets);
}

/// AES-128-ECB 加密 (无填充)
Uint8List _ecbEncrypt(Uint8List data, Uint8List key) {
  final e = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.ecb, padding: null));
  return Uint8List.fromList(e.encryptBytes(data).bytes);
}

/// 取指定 PID 的全部 PES 负载 (跳过 PES 头), 用于断言解密结果
Uint8List _extractPesPayload(Uint8List ts, int pid) {
  final parts = <int>[];
  var headerRemaining = 0;
  var started = false;
  for (var off = 0; off + 188 <= ts.length; off += 188) {
    if (ts[off] != 0x47) continue;
    final cur = ((ts[off + 1] & 0x1f) << 8) | ts[off + 2];
    if (cur != pid) continue;
    final pusi = (ts[off + 1] & 0x40) != 0;
    final hasAdapt = (ts[off + 3] & 0x20) != 0;
    final hasPayload = (ts[off + 3] & 0x10) != 0;
    if (!hasPayload) continue;
    var start = off + 4;
    if (hasAdapt) start += ts[off + 4] + 1;
    if (pusi) {
      headerRemaining = 9 + ts[start + 8];
      started = true;
    }
    if (!started) continue;
    var from = start;
    if (headerRemaining > 0) {
      final skip =
          headerRemaining < (off + 188 - from) ? headerRemaining : (off + 188 - from);
      from += skip;
      headerRemaining -= skip;
    }
    parts.addAll(ts.sublist(from, off + 188));
  }
  return Uint8List.fromList(parts);
}

Uint8List _makePayload(int len, {int seed = 1}) {
  final out = Uint8List(len);
  for (var i = 0; i < len; i++) {
    out[i] = (seed * 31 + i * 7) & 0xff;
  }
  return out;
}

void main() {
  final key = base64.decode(_keyB64);

  test('单包 PES: 负载被还原, 且 TS 长度/同步字节不变', () {
    const pid = 0x100;
    final plain = _makePayload(32);
    final cipher = _ecbEncrypt(plain, key);
    final ts = _buildTs(pid: pid, pesPayload: cipher);

    final out = SceTsSampleDecryptor.decryptTs(ts, key);
    expect(out.length, ts.length);
    expect(out[0], 0x47);

    final got = _extractPesPayload(out, pid);
    // TS 包尾部为填充字节, 只比对 PES 负载部分
    expect(got.sublist(0, plain.length), plain);
  });

  test('多包 PES: 跨包 16 字节对齐被正确还原', () {
    const pid = 0x101;
    // 400 字节负载 → 跨 3 个 188 包, 包边界不是 16 的倍数
    final plain = _makePayload(400, seed: 7);
    final cipher = _ecbEncrypt(plain, key);
    final ts = _buildTs(pid: pid, pesPayload: cipher);
    expect(ts.length, 3 * 188);

    final out = SceTsSampleDecryptor.decryptTs(ts, key);
    expect(out.length, ts.length);
    final got = _extractPesPayload(out, pid);
    expect(got.sublist(0, plain.length), plain);
  });

  test('长度非 16 倍数: 尾部按站点行为保留密文', () {
    const pid = 0x102;
    final plain = _makePayload(400 + 5, seed: 3); // 405 字节
    final cipher = _ecbEncrypt(plain.sublist(0, 400), key);
    final tail = plain.sublist(400); // 未加密的 5 字节尾巴 (模拟站点保留)
    final ts = _buildTs(
        pid: pid, pesPayload: Uint8List.fromList(<int>[...cipher, ...tail]));

    final out = SceTsSampleDecryptor.decryptTs(ts, key);
    final got = _extractPesPayload(out, pid);
    expect(got.sublist(0, 400), plain.sublist(0, 400));
    // 尾部 5 字节未参与解密, 原样保留
    expect(got.sublist(400, 405), tail);
  });

  test('音频 PID (0xC0) 同样被解密', () {
    const pid = 0x103;
    final plain = _makePayload(64, seed: 11);
    final ts = _buildTs(
        pid: pid, pesPayload: _ecbEncrypt(plain, key), streamId: 0xc0);
    final out = SceTsSampleDecryptor.decryptTs(ts, key);
    expect(_extractPesPayload(out, pid).sublist(0, plain.length), plain);
  });

  test('非 PES 的 PSI 表 (PAT/PMT) 不被改动', () {
    // 直接拼一个 PID 0 的 PAT 包: 负载不以 00 00 01 开头 → 保持原样
    final packet = Uint8List(188);
    packet[0] = 0x47;
    packet[1] = 0x40; // PUSI + PID 高 5 位 = 0
    packet[2] = 0x00;
    packet[3] = 0x10; // 仅负载, 无 adaptation
    packet[4] = 0x00; // pointer_field
    packet[5] = 0x00; // table_id (PAT)
    packet[6] = 0xb0;
    for (var i = 7; i < 188; i++) {
      packet[i] = 0xff;
    }
    final out = SceTsSampleDecryptor.decryptTs(packet, key);
    expect(out, packet);
  });

  test('错误的密钥: 输出长度不变但内容不同', () {
    const pid = 0x104;
    final plain = _makePayload(32, seed: 5);
    final ts = _buildTs(pid: pid, pesPayload: _ecbEncrypt(plain, key));
    final wrongKey = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final out = SceTsSampleDecryptor.decryptTs(ts, wrongKey);
    expect(out.length, ts.length);
    expect(out[0], 0x47);
    expect(_extractPesPayload(out, pid).sublist(0, plain.length), isNot(plain));
  });

  test('空/过短输入原样返回, 不抛异常', () {
    expect(SceTsSampleDecryptor.decryptTs(Uint8List(0), key).length, 0);
    final short = Uint8List.fromList([0x47, 0x40, 0x10]);
    expect(SceTsSampleDecryptor.decryptTs(short, key), short);
  });

  test('decryptTsWithVpk 与 deriveVpk 联动 (端到端密钥)', () {
    const pid = 0x105;
    final vpk = SceCipher.deriveVpk(
      secret: 'TKa0BYk5eSw3kbY2',
      rand: 'PvnIM6oB496oxQ+veIon1Q==',
      plaintext: 'UrQqsyHgWC/pnFHU8PXPV0MUBwvOAcuBQ0nOj3+Ic5g=',
    );
    expect(vpk.length, 16);
    final plain = _makePayload(48, seed: 21);
    final ts = _buildTs(pid: pid, pesPayload: _ecbEncrypt(plain, vpk));
    final out = SceTsSampleDecryptor.decryptTsWithVpk(ts, vpk);
    expect(_extractPesPayload(out, pid).sublist(0, plain.length), plain);
  });
}
