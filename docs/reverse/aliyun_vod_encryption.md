# 阿里云私有加密 (AliyunVoDEncryption) 逆向结论

产物来源：`mstplayer-v3.0.37.min.js` (webpack 模块 120) + `ali-hls.min.1.1.2.js`
所有结论均在 Node harness 中与站点实现**逐字节比对通过**，并在真实服务端联调验证。

---

## 一、三个 `_sce_*` 函数的真实语义

| 站点函数          | 语义                                          | Dart 对应 |
|-------------------|-----------------------------------------------|-----------|
| `_sce_r_skjhfnck` | 生成 16 字符客户端密钥材料 `l`                | `SceCipher.genClientSecret()` |
| `_sce_lgtcaygl`   | `Rand = RSA-PKCS#1 v1.5_pub(l)` → base64      | `SceCipher.deriveRand(secret)` |
| `_sce_dlgtqred`   | 由 `(l, 响应Rand, Plaintext)` 派生 16 字节密钥 | `SceCipher.deriveVpk(...)` |

### 1. `genClientSecret`

16 个字符，逐个取自 50 字符串集（还原自混淆数组 `e[1]`，每项 `charCode - 422`）：

```
ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz234567890
```

长度常量 = `441 - 0b110101001 = 16`。

### 2. `deriveRand`：RSA-512 + PKCS#1 v1.5

站点内嵌的 512 位公钥（还原自 `t[13]` 反序 + `e[13]` + `t[17]` 逐项 `charCode - 354` + `t[19]`）：

```
-----BEGIN PUBLIC KEY-----
MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAIcLeIt2wmIyXckgNhCGpMTAZyBGO+nk0/IdOrhIdfRR
gBLHdydsftMVPNHrRuPKQNZRslWE1vvgx80w9lCllIUCAwEAAQ==
-----END PUBLIC KEY-----
```

- n = `870b788b76c262325dc920361086a4c4c06720463be9e4d3f21d3ab84875f4518012c777276c7ed3153cd1eb46e3ca40d651b25584d6fbe0c7cd30f650a59485` (512 bit)
- e = 65537
- 填充为标准 PKCS#1 v1.5 type 2（`ae` 就是未改写的 JSEncrypt；已用"自造密钥对 + Node 私钥解密"实测确认）
- 输出 64 字节 / 88 字符 base64

### 3. `deriveVpk`

```
k1 = utf8(md5_hex(l)[8:24])
Y  = utf8(AES-128-CBC(k1, iv=k1).decrypt(响应Rand))     ← 服务端挑的加盐串
k2 = utf8(md5_hex(l + Y)[8:24])
G  = utf8(AES-128-CBC(k2, iv=k1).decrypt(Plaintext))    ← 内容是 base64(16字节密钥)
key = base64_decode(G)
```

注意两点非对称/易错细节：
- 两次解密的 IV **都是 k1**（第二次换密钥不换 IV）；
- 去填充用 crypto-js 的宽松策略（只读末字节截断，不校验），因此密钥错配时不抛异常而是得到垃圾。

---

## 二、最关键的反转：这不是整段 AES-128

m3u8 里的 `#EXT-X-KEY:MEATHOD=AES-128,URI="<base64块>"` 是**诱饵**：

- `MEATHOD` 是阿里云的拼写缺陷 → 标准解析器读不到 `METHOD=` → 整段不解密；
- URI 不是 URL，而是 132 字节的密钥块（`36 字节 UUID + 96 字节负载`），第三方取不到。

站点自己的播放器走的是**样本级加密**（见 ali-hls 中 `q(pes, this.config._vpk)`）：

```
TS 容器（188 包头 / 0x47 / PAT / PMT）         ← 完全明文
└─ PES 负载（视频 0xE0 / 音频 0xC0）           ← AES-128-ECB(_vpk)
```

即：对每个 PES 包，跳过 `9 + PES_header_data_length` 字节头，剩余负载按 16 字节分组
ECB 解密；长度非 16 倍数时只解前 `floor(len/16)*16` 字节，尾部保留密文。

### 实测证据（lessonId 91251，720P/SD 档）

```
原始分片首 4 字节        : 47 40 11 10           → TS 容器明文
视频 PID 256 (0xE0) 密文: db2efea5b5b11f969dfef7f7392b4dff
              ECB 解密后: 0000000109f0 0000000167640028acc8   ← AUD(0x09) + SPS(0x67)
音频 PID 257 (0xC0)     : fff150801722a02111450014500146f9    ← AAC ADTS 同步头 0xFFF
```

`SceTsSampleDecryptor` 的输出与 Node 独立实现**逐字节一致**，且输出长度与输入相同
（ECB 不改变长度 → TS 包结构无需重封，可直接拼接后 ffmpeg 封装）。

---

## 三、实时播放的解法：本地透明解密代理

mpv/ffmpeg 没有"解 PES 负载"这类滤镜，所以直连 CDN 必然是乱码。正解是
在 127.0.0.1 起一个 HTTP 服务，对 mpv 伪装成普通 HLS 源
（`lib/features/player/domain/services/aliyun_hls_proxy.dart`）：

```text
mpv ─GET /0/playlist.m3u8─▶ 代理 ─GET 原m3u8(带 Origin/Referer)─▶ CDN
   ◀─ 删掉诱饵 KEY 行、分片指向本代理 ────────────────────────────┘
mpv ─GET /0/seg/12.ts─────▶ 代理 ─GET 原分片─▶ CDN → 样本级解密 → 明文 TS
```

- 边下边播，不阻塞等待；mpv 按需请求分片 → 天然支持拖动/seek；
- 每档清晰度各注册一份 playlist，切档同样走代理；
- LRU 缓存已解密分片（默认 24 段）+ inflight 去重（防 mpv 并发重复下载）；
- 播放页关闭 / 切线路时关闭 server 释放端口。

真机验证输出：

```
代理已启动: http://127.0.0.1:50780/0/playlist.m3u8
  代理 playlist 4637 字节, 含 EXT-X-KEY: false
  代理分片: http://127.0.0.1:50780/0/seg/0.ts
    552344 字节, 首字节 0x47, 首个 000001 起始码 @200 → OK (明文 TS)
```

Web 端无法起 `HttpServer`，仍只能提示改用桌面/移动端客户端。

## 四、请求侧契约（服务端已认可）

`Definition` + `Rand` 的播放模式才下发密钥素材：

- 带 `Definition` 时**不能**带 `ResultType`（站点抓包同样如此）；
- 不带 `Definition` 必须带 `ResultType=Multiple`，此时 `Plaintext` 恒为空（只能枚举档位）；
- 私有加密必须带 `PlayConfig={"EncryptType":"AliyunVoDEncryption"}`；
- `Rand` 非法 → `400 InvalidParameter ... "Rand" is not valid.`

因此完整流程是两步：先 `Multiple` 枚举出各档 `Definition`，再逐档用**新的** `l/Rand`
请求拿该档的 `Rand`/`Plaintext` 派生密钥。

---

## 五、复用产物

> 以下脚本与中间产物均位于仓库 `debug/AliyunVoDEncryption/` 目录。

| 文件 | 用途 |
|------|------|
| `mstplayer-v3.0.37.min.js` | 站点播放器 bundle（1.24MB，必须解压） |
| `ali-hls.min.1.1.2.js` | 消费 `_vpk` 的 HLS 播放器 |
| `extract.py` | 切出第三个 webpack bundle 并注入 `__WREQ` 导出 |
| `loader.js` | Node 环境桩 + 取出模块 120 |
| `mk_probe.py` / `bundle3_probe.js` | 打印闭包内的两个混淆字符串数组 |
| `decode_consts.py` | 离线还原字符集 / PEM / 各常量串 |
| `gen_vectors.js` / `vectors.json` | 生成并固化测试向量 |
| `validate_ref.js` | 干净参考实现 vs oracle 逐位比对（20/20 通过） |
| `verify_sample2.js` | 真实 TS 的样本级解密验证 |
| `public.pem` | 解出的 512 位 RSA 公钥 |

### 逆向要点（可复用方法）

1. 站点 bundle 是多个 webpack 实例拼接，目标模块在**第三个**实例里；
2. 用 `curl` 取不到明文（必须 `--compressed`，且 Git-Bash 的 curl 不带该能力 → 用 Python + gzip）；
3. 与其硬读控制流扁平化代码，不如**把闭包里的混淆字符串数组 dump 出来**再离线还原；
4. 拿到数组后按 "每个混淆串都是 XOR/减法常量" 的规律即可全部解出，剩下的状态机很好读；
5. 验证 RSA 填充类型可用"同 bundle 生成密钥对 → 自造私钥解密"的办法，无需目标私钥。
