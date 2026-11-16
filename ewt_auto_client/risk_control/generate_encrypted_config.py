#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RiskControl 配置加密脚本
========================

将 risk_control_config.json 加密为带标记的密文, 供 App 远程读取解密。

使用流程:
  1. 编辑同目录 risk_control_config.json (功能开关 / 启动密码 / 过期 / 一键跑路)
  2. 运行:  python generate_encrypted_config.py
  3. 将终端/encrypted_config.txt 中的密文 (含首尾 @####...#@ 标记行) 手动
      粘贴到: https://sharechain.qq.com/9c1f20bdc8df0fe241dfdf9eda2131b3?qq_aio_chat_type=2
  4. App 启动时拉取该页面, 提取标记间内容并解密加载配置

纯 Python 实现, 无第三方依赖。

加密管线 (与 Dart 端 lib/core/risk_control/risk_control_crypto.dart 逐字节一致):
  raw(UTF-8) -> PKCS7(块16) -> ChaCha20(RFC8439 变式, 20轮) 流加密
            -> 8轮 Feistel 差分(块16, 子钥=sha256(派生钥+R<n>))
            -> 字节反序 -> 变种Base64(自定义字母表) -> @标记@ 包裹

密钥派生 (master = sha256(seed) 再派生三类子钥):
  ChaChaKey  = sha256(master + "::K1::")[:32]
  ChaChaNonce= sha256(master + "::N1::")[:12]
  FeistelKey = sha256(master + "::F1::")[:32]

ChaCha20 注意: 方块序列化为每字 4 字节**大端** (非 RFC 标准的小端),
  quarter-round 仅回写 a (b/c/d 的中间态丢弃) —— 这是与 Dart 端刻意保持一致的
  确定性变式, 自洽可逆; Python 必须逐字节复刻, 否则加密结果不一致。
"""

import base64
import hashlib
import json
import os
import re
import sys

SEED = b"xxhy123"
MARKER = "@############################@"

STD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
CUS_ALPHABET = "-_9876543210zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA"

_ENC_TABLE = str.maketrans(STD_ALPHABET, CUS_ALPHABET)
_DEC_TABLE = str.maketrans(CUS_ALPHABET, STD_ALPHABET)


# ─────────────────────────── 密钥派生 ───────────────────────────

def derive_keys():
    """派生子钥三元组 (chaChaKey, nonce, feistelKey)。"""
    master = hashlib.sha256(SEED).digest()
    cc_key = hashlib.sha256(master + b"::K1::").digest()
    cc_nonce = hashlib.sha256(master + b"::N1::").digest()[:12]
    feistel = hashlib.sha256(master + b"::F1::").digest()
    return cc_key, cc_nonce, feistel


# ─────────────────────────── ChaCha20 (Dart 逐字节一致变式) ───────────────────────────

def _rol32(x, n):
    n &= 31
    if n == 0:
        return x & 0xFFFFFFFF
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF


def _qr(a, b, c, d):
    """quarter-round, 仅回写 a (复刻 Dart, 保持确定性变式)。"""
    a = (a + b) & 0xFFFFFFFF
    d = _rol32(d ^ a, 16)
    c = (c + d) & 0xFFFFFFFF
    b = _rol32(b ^ c, 12)
    a = (a + b) & 0xFFFFFFFF
    d = _rol32(d ^ a, 8)
    c = (c + d) & 0xFFFFFFFF
    b = _rol32(b ^ c, 7)
    return a


def chacha20_block(key, nonce, counter):
    """构造 64 字节 keystream 块 (逐字节对齐 Dart `ChaCha20._block`)。"""
    state = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574]
    for i in range(8):
        state.append(int.from_bytes(key[i * 4:i * 4 + 4], "little"))
    state.append(counter & 0xFFFFFFFF)
    for i in range(3):
        state.append(int.from_bytes(nonce[i * 4:i * 4 + 4], "little"))

    x = list(state)
    for _ in range(10):  # 20 轮 = 10 个双轮
        # 列轮
        x[0] = _qr(x[0], x[4], x[8], x[12])
        x[1] = _qr(x[1], x[5], x[9], x[13])
        x[2] = _qr(x[2], x[6], x[10], x[14])
        x[3] = _qr(x[3], x[7], x[11], x[15])
        # 对角轮
        x[0] = _qr(x[0], x[5], x[10], x[15])
        x[1] = _qr(x[1], x[6], x[11], x[12])
        x[2] = _qr(x[2], x[7], x[8], x[13])
        x[3] = _qr(x[3], x[4], x[9], x[14])

    x = [(x[i] + state[i]) & 0xFFFFFFFF for i in range(16)]
    return b"".join(w.to_bytes(4, "big") for w in x)  # 大端序列化


def chacha20_apply(data, key, nonce, init_counter=0):
    """生成 keystream 与 data 逐字节异或 (同步流)。"""
    out = bytearray()
    counter = init_counter
    for off in range(0, len(data), 64):
        ks = chacha20_block(key, nonce, counter)
        counter += 1
        out += bytes(a ^ b for a, b in zip(data[off:off + 64], ks))
    return bytes(out)


# ─────────────────────────── Feistel 差分 ───────────────────────────

def _be64(b):
    return int.from_bytes(b, "big")


def _rol64(x, n):
    n &= 63
    if n == 0:
        return x & 0xFFFFFFFFFFFFFFFF
    return ((x << n) | (x >> (64 - n))) & 0xFFFFFFFFFFFFFFFF


def _sub_key(feistel, rnd):
    return hashlib.sha256(feistel + ("R%d" % rnd).encode()).digest()[:8]


def feistel_encrypt(data, feistel):
    out = bytearray()
    for blk in range(0, len(data), 16):
        L = _be64(data[blk:blk + 8])
        R = _be64(data[blk + 8:blk + 16])
        for r in range(8):
            sub = _be64(_sub_key(feistel, r))
            f = _rol64(R, (r + 1) * 3) ^ sub
            L, R = R, L ^ f
        out += L.to_bytes(8, "big") + R.to_bytes(8, "big")
    return bytes(out)


def feistel_decrypt(data, feistel):
    out = bytearray()
    for blk in range(0, len(data), 16):
        L = _be64(data[blk:blk + 8])
        R = _be64(data[blk + 8:blk + 16])
        for r in range(7, -1, -1):
            sub = _be64(_sub_key(feistel, r))
            oldR = L
            oldL = R ^ _rol64(oldR, (r + 1) * 3) ^ sub
            L, R = oldL, oldR
        out += L.to_bytes(8, "big") + R.to_bytes(8, "big")
    return bytes(out)


# ─────────────────────────── PKCS7 + 变种 Base64 ───────────────────────────

def pkcs7_pad(data, block):
    padlen = block - (len(data) % block)
    return data + bytes([padlen]) * padlen


def pkcs7_unpad(data, block):
    if not data:
        return data
    padlen = data[-1]
    if padlen <= 0 or padlen > block:
        return data
    return data[:-padlen]


def variant_b64_encode(data):
    std = base64.b64encode(data).decode("ascii")
    return std.translate(_ENC_TABLE)


def variant_b64_decode(text):
    std = text.translate(_DEC_TABLE)
    return base64.b64decode(std)


# ─────────────────────────── 加解密主入口 ───────────────────────────

def encrypt_config(json_str):
    key, nonce, feistel = derive_keys()
    raw = pkcs7_pad(json_str.encode("utf-8"), 16)
    ct = chacha20_apply(raw, key, nonce, 0)
    mixed = feistel_encrypt(ct, feistel)
    rev = mixed[::-1]
    b64 = variant_b64_encode(rev)
    return f"{MARKER}\n{b64}\n{MARKER}"


def decrypt_config(payload):
    key, nonce, feistel = derive_keys()
    m = re.search(re.escape(MARKER) + r"([\s\S]*?)" + re.escape(MARKER), payload)
    if not m:
        raise ValueError("未找到配置标记")
    text = "".join(m.group(1).split())  # 去所有空白字符
    rev = variant_b64_decode(text)[::-1]
    ct = feistel_decrypt(rev, feistel)
    plain = chacha20_apply(ct, key, nonce, 0)
    return pkcs7_unpad(plain, 16).decode("utf-8")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "risk_control_config.json")
    out_path = os.path.join(here, "encrypted_config.txt")

    if not os.path.exists(cfg_path):
        print("配置文件不存在:", cfg_path, file=sys.stderr)
        sys.exit(1)

    with open(cfg_path, "r", encoding="utf-8") as f:
        json_str = f.read()
    json.loads(json_str)  # 校验 JSON 合法性

    encrypted = encrypt_config(json_str)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(encrypted)

    print(encrypted)
    print("\n[OK] 密文已写入:", out_path)
    print("请将以上密文 (含首尾标记行) 手动粘贴到:")
    print("https://sharechain.qq.com/9c1f20bdc8df0fe241dfdf9eda2131b3?qq_aio_chat_type=2")

    # 往返校验 (自洽性)
    try:
        back = decrypt_config(encrypted)
        assert back == json_str, "往返不一致"
        print("[self-test] 解密往返校验通过")
    except Exception as e:  # noqa
        print("[self-test] FAILED:", e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()