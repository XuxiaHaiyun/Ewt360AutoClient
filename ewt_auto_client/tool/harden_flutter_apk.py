# -*- coding: utf-8 -*-
"""Flutter APK 去特征加固后处理脚本。

原理: Flutter 引擎的加载名硬编码在 classes.dex 的字符串池中
  - "libapp.so"      (Dart AOT 产物文件名)
  - "flutter"        (System.loadLibrary("flutter") -> libflutter.so)
  - "flutter_assets" (资源目录常量)
对三者做**随机**等长替换, 且替换名必须落在字符串池中原位置的字典序窗口内
(string_ids 要求严格有序, 否则 ART/dexdump 校验失败拒载); 同步改名 APK
条目并等长替换 libfluttec 类 so 内部出现的同名字符串。每次运行生成不同
的随机名, 避免加固产物自身形成新指纹。改名后 blutter 等基于
libapp.so / libflutter_assets 特征匹配的工具失效。

流程: 读 APK -> 随机规划映射(含有序性校验) -> dex 补丁+重算 SHA-1/Adler32
-> 自写 zip 重打包 (.so 保持 STORED 且 16 字节对齐, 满足
extractNativeLibs=false) -> apksigner 用 debug key 重签名 (改动字节后原
v2 签名失效, 必须重签)。

用法:
  python tool/harden_flutter_apk.py <输入.apk> [输出.apk]
默认输出: <输入名去掉.apk>-hardened.apk, 同时写出 <输出>.rename-map.json。
"""

import json
import random
import string
import struct
import sys
import zlib
from pathlib import Path

# 参与替换的特征串
TARGET_LIBAPP = b"libapp.so"  # 9, 产物文件名 (含 .so 后缀)
TARGET_ENGINE = b"flutter"  # 7, loadLibrary 名
TARGET_ASSETS = b"flutter_assets"  # 14, 资源目录常量

# 随机名生成规则: 各目标的排序窗口决定了可用结构 ——
#   libapp.so      ∈ ('lib', 'libass')            -> 'liba'+[0-9a-r]+???+'.so'
#   flutter        ∈ ('flush', 'flutter-assets-dir'] -> 'flut'+[0-9a-e]+?? (避免拼出 flutter)
#   flutter_assets ∈ ('flutterUiResizeListeners', 'flutter_deeplinking_enabled')
#                   -> 8 字符只能是 '_', 后随 [0-9abc] => 'flutter_'+[0-9abc]+?????
# 即后两者的随机空间受字典序硬约束 (目录名必然含 flutter 前缀),
# 但对"精确匹配 flutter_assets / libflutter.so"的工具依然有效。
def _rand(length: int, rng: random.Random) -> bytes:
    alphabet = string.ascii_lowercase + string.digits
    return "".join(rng.choice(alphabet) for _ in range(length)).encode()


def gen_candidate(target: bytes, rng: random.Random) -> bytes:
    if target == TARGET_LIBAPP:
        return b"liba" + _rand(1, rng) + _rand(1, rng) + b".so"
    if target == TARGET_ENGINE:
        return b"flut" + _rand(1, rng) + _rand(2, rng)
    if target == TARGET_ASSETS:
        return b"flutter_" + _rand(1, rng) + _rand(5, rng)
    raise ValueError(target)


def read_uleb(buf: bytes, p: int):
    result = 0
    shift = 0
    while True:
        b = buf[p]
        p += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, p


def dex_strings(data: bytes) -> list:
    n = int.from_bytes(data[0x38:0x3C], "little")
    off = int.from_bytes(data[0x3C:0x40], "little")
    out = []
    for i in range(n):
        p = int.from_bytes(data[off + 4 * i: off + 4 * i + 4], "little")
        _, p = read_uleb(data, p)
        end = data.index(0, p)
        out.append(data[p:end])
    return out


# 特征子串黑名单。注意: 不含 b"flutter" —— flutter_assets 的排序窗口
# 决定其 8 字符只能为 '_', 候选必然含 flutter 前缀 (字典序硬约束);
# 引擎名窗口 (第4位 <= 'e') 则天然不可能拼出完整 'flutter'。
FORBIDDEN_MARKERS = (b"libapp", b"dart", b"snapshot", b"kernel")


def append_decoy(data: bytes, rng: random.Random) -> bytes:
    """so 级加固 (保留形态): 仅在文件尾部追加随机填充与诱饵字符串。

    说明: 曾尝试抹除/清洗 ELF 节头表, 但 Android 15 bionic 对节表做了
    体系化硬化 (实测 PGX110 三连败):
      1) e_shentsize 必须恒为 0x40;
      2) e_shnum>0 时 e_shstrndx 必须指向真实 SHT_STRTAB;
      3) 节表存在时必须包含 .dynamic 节 (与 PT_DYNAMIC 对应)。
    即: 要么提供完整一致的节表, 要么完全没有节表 (e_shoff=e_shnum=0,
    走传统 PT_DYNAMIC 路径 —— 但该形态未实测, 不做赌注)。
    故放弃节表篡改, 保留与 ELF 结构无关的加固: 随机改名/dex 补丁/诱饵。
    诱饵位于所有 PT_LOAD 之外, 不被映射, 对加载零影响。
    """
    decoy = rng.randbytes(64 * 1024)
    for _ in range(24):
        decoy += _rand(rng.randint(8, 24), rng) + b"\x00"
    return data + decoy


def mutf16_key(raw: bytes) -> str:
    """MUTF-8 字节串 -> 可按 UTF-16 码元序比较的 Python 字符串。

    dex 字符串排序依据是 UTF-16 码元, 而非原始字节序 (池头部存在 C0 80
    即 MUTF-8 的 NUL, 字节序比较会得出错误结论)。MUTF-8 与 CESU-8 相同
    (NUL 例外): 把 C0 80 还原为 00 后按 utf-8 + surrogatepass 解码即可,
    代理对还原为单个 surrogate 字符, 与码元序一致。
    """
    return raw.replace(b"\xc0\x80", b"\x00").decode(
        "utf-8", errors="surrogatepass"
    )


def plan_random_renames(dex_data: bytes, max_tries: int = 500) -> dict:
    """为三个特征串规划随机替换名。

    约束: 等长; 解码后严格落在原位置的排序窗口 (prev, next) 内; 不与池中
    任何现有串重复; 不含特征子串。单点替换只需满足局部窗口即可保证整个
    有序列表仍然有序 (其余项不变), 因此无需全局重验。
    """
    pool = dex_strings(dex_data)
    existing = {mutf16_key(s) for s in pool}
    rng = random.SystemRandom()

    chosen = {}
    for target in (TARGET_LIBAPP, TARGET_ENGINE, TARGET_ASSETS):
        i = pool.index(target)
        lo = mutf16_key(pool[i - 1]) if i > 0 else ""
        hi = mutf16_key(pool[i + 1]) if i + 1 < len(pool) else None
        for _ in range(max_tries):
            c = gen_candidate(target, rng)
            key = mutf16_key(c)
            if key <= lo or (hi is not None and key >= hi):
                continue
            if key in existing or key in {mutf16_key(v) for v in chosen.values()}:
                continue
            if any(m in c for m in FORBIDDEN_MARKERS):
                continue
            chosen[target] = c
            break
        else:
            raise RuntimeError(
                f"随机替换名规划失败: {target!r} 排序窗口过窄 "
                f"({lo!r} ~ {hi!r}), 请人工指定映射"
            )
    return chosen


def patch_bytes(data: bytes, mapping: dict) -> bytes:
    """等长字节替换, 仅处理实际出现的键; 长键优先防止前缀互毁。"""
    for old, new in sorted(mapping.items(), key=lambda kv: -len(kv[0])):
        assert len(old) == len(new), f"长度不一致: {old} vs {new}"
        data = data.replace(old, new)
    return data


def patch_dex(data: bytes, mapping: dict) -> bytes:
    """解析 dex 字符串池, 对命中目标串的字符串项做等长原地替换。

    只替换字符串池中的"完整字符串项", 不会误伤其他位置的相同字节序列。
    补丁后必须重算 dex 头部的 SHA-1 签名 (offset 12, 覆盖 [32..]) 与
    Adler-32 校验和 (offset 8, 覆盖 [12..]), 否则 ART 校验失败拒载整个 dex。
    """
    buf = bytearray(data)
    n = int.from_bytes(buf[0x38:0x3C], "little")
    off = int.from_bytes(buf[0x3C:0x40], "little")
    replaced = []
    for i in range(n):
        p = int.from_bytes(buf[off + 4 * i: off + 4 * i + 4], "little")
        _, p = read_uleb(buf, p)
        end = buf.index(0, p)
        raw = bytes(buf[p:end])
        if raw in mapping:
            new = mapping[raw]
            assert len(new) == len(raw)
            buf[p:end] = new
            replaced.append(raw.decode())
    print(f"    dex 补丁: {replaced}")

    import hashlib

    buf[12:32] = hashlib.sha1(bytes(buf[32:])).digest()
    buf[8:12] = struct.pack("<I", zlib.adler32(bytes(buf[12:])) & 0xFFFFFFFF)
    return bytes(buf)


def write_zip(out_path: Path, entries):
    """entries: list[(name, data, compress_type)]。
    .so 一律 STORED 且数据起始 16 字节对齐 (extractNativeLibs=false 要求);
    其余按给定压缩方法写入。仅基础 zip 功能, 不处理 zip64。
    """
    central = []
    with open(out_path, "wb") as f:
        for name, data, method in entries:
            name_b = name.encode("utf-8")
            is_so = name_b.endswith(b".so")
            if is_so:
                method = 0  # STORED
            crc = zlib.crc32(data) & 0xFFFFFFFF
            if method == 0:
                payload = data
            else:
                co = zlib.compressobj(6, zlib.DEFLATED, -15)
                payload = co.compress(data) + co.flush()

            offset = f.tell()
            header_size = 30 + len(name_b)
            pad = (-((offset + header_size) % 16)) % 16 if is_so else 0
            extra = b"\x00" * pad
            f.write(
                struct.pack(
                    "<4s5H3I2H",
                    b"PK\x03\x04",
                    20, 0,
                    method, 0, 0,
                    crc,
                    len(payload),
                    len(data),
                    len(name_b),
                    len(extra),
                )
            )
            f.write(name_b)
            f.write(extra)
            f.write(payload)

            central.append((name_b, method, crc, len(payload), len(data), offset))

        cd_start = f.tell()
        for name_b, method, crc, csize, usize, offset in central:
            f.write(
                struct.pack(
                    "<4s6H3I5H2I",
                    b"PK\x01\x02",
                    20, 20, 0,
                    method, 0, 0,
                    crc, csize, usize,
                    len(name_b), 0, 0, 0, 0, 0,
                    offset,
                )
            )
            f.write(name_b)
        cd_size = f.tell() - cd_start
        f.write(
            struct.pack(
                "<4s4H2LH",
                b"PK\x05\x06",
                0, 0, len(central), len(central),
                cd_size, cd_start, 0,
            )
        )


def sign(apk: Path):
    """用 debug keystore 重签名 (gradle release 默认即 debug 签名)。"""
    import subprocess

    sdk_dir = None
    for line in (Path(__file__).parent.parent / "android" / "local.properties").read_text().splitlines():
        if line.startswith("sdk.dir="):
            sdk_dir = Path(line[8:].strip())
    ks = Path.home() / ".android" / "debug.keystore"
    assert sdk_dir and ks.exists(), "未找到 SDK 或 debug.keystore"
    apksigners = sorted((sdk_dir / "build-tools").glob("*/apksigner.bat"), reverse=True)
    assert apksigners, "未找到 apksigner"
    subprocess.run(
        [
            str(apksigners[0]), "sign",
            "--ks", str(ks),
            "--ks-pass", "pass:android",
            "--key-pass", "pass:android",
            "--out", str(apk), str(apk),
        ],
        check=True,
    )
    subprocess.run([str(apksigners[0]), "verify", str(apk)], check=True)
    print("签名校验通过")


def main():
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_name(
        src.stem + "-hardened.apk"
    )
    from zipfile import ZipFile

    with ZipFile(src) as z:
        dex_data = next(
            z.read(n) for n in z.namelist() if n.endswith("classes.dex")
        )
    mapping = plan_random_renames(dex_data)
    printable = {
        k.decode(): v.decode() for k, v in mapping.items()
    }
    print(f"    随机映射: {printable}")

    engine_name = mapping[TARGET_ENGINE].decode()
    engine_file = f"lib{engine_name}.so"
    assets_dir = mapping[TARGET_ASSETS].decode()

    # dex 用完整映射; so 内容只补长串且按长度降序, 不碰裸 b"flutter"
    so_patch = {
        TARGET_ASSETS: mapping[TARGET_ASSETS],
        TARGET_LIBAPP: mapping[TARGET_LIBAPP],
    }

    def rename_entry(name: str) -> str:
        parts = name.rsplit("/", 1)
        base = parts[-1]
        if base == TARGET_LIBAPP.decode():
            base = mapping[TARGET_LIBAPP].decode()
        elif base == "libflutter.so":
            base = engine_file
        out = "/".join(parts[:-1] + [base]) if len(parts) > 1 else base
        if out.startswith(f"assets/{TARGET_ASSETS.decode()}/"):
            out = f"assets/{assets_dir}/" + out[len(f"assets/{TARGET_ASSETS.decode()}/"):]
        return out

    entries = []
    wipe_rng = random.SystemRandom()
    app_lib_name = mapping[TARGET_LIBAPP].decode()
    with ZipFile(src) as z:
        for info in z.infolist():
            name = rename_entry(info.filename)
            data = z.read(info.filename)
            if name.endswith(".dex"):
                data = patch_dex(data, mapping)
            elif name.endswith(app_lib_name):
                data = append_decoy(
                    patch_bytes(data, so_patch), wipe_rng
                )
            elif name.endswith(engine_file):
                data = append_decoy(
                    patch_bytes(data, so_patch), wipe_rng
                )
            entries.append((name, data, info.compress_type))

    write_zip(dst, entries)
    sign(dst)
    dst.with_name(dst.name + ".rename-map.json").write_text(
        json.dumps(printable, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"完成: {dst}")
    print(f"映射已记录: {dst.with_name(dst.name + '.rename-map.json')}")


if __name__ == "__main__":
    main()
