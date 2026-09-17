#!/usr/bin/env python3
"""获取可随套件分发的 Perl 运行时。

为什么不用系统 Perl：群晖 DSM 默认不安装 Perl，威联通各机型差异也很大；
而 ExifTool 本质上是一个 Perl 脚本，应用还会用到 `-if` 表达式与
`-overwrite_original` 等特性，因此必须带上真正的 Perl 解释器。

为什么选 Debian 9(stretch)：该版本基于 glibc 2.24，能覆盖 DSM 7.0/7.1
（glibc 2.26）与 QTS 5.x 全部机型。Perl 自身引用的最高符号版本甚至只有
GLIBC_2.14，比基线更宽松，留足了余量。stretch 已进入归档，软件包内容
不再变化，因此解析出的 .deb 是完全可复现的。

用法：
    fetch-perl-runtime.py --arch amd64 --out <目录>
"""

from __future__ import annotations

import argparse
import gzip
import io
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ARCHIVE_BASE = "http://archive.debian.org/debian"
SUITE = "stretch"

# perl / libperl 为 ExifTool 提供解释器与核心模块；
# 其余三个是 libperl 的动态链接依赖，缺失会导致 libperl.so 无法加载。
REQUIRED_PACKAGES = [
    "perl-base",
    "perl",
    "perl-modules-5.24",
    "libperl5.24",
    "libbz2-1.0",
    "libdb5.3",
    "libgdbm3",
]

# 纯文档，删掉可显著缩小体积
PRUNE_DIRS = [
    "usr/share/doc",
    "usr/share/man",
    "usr/share/lintian",
]
PRUNE_SUFFIXES = (".pod",)


def log(message: str) -> None:
    print(f"[perl-runtime] {message}", flush=True)


def load_index(arch: str, cache_dir: str) -> dict[str, dict[str, str]]:
    os.makedirs(cache_dir, exist_ok=True)
    cached = os.path.join(cache_dir, f"Packages-{SUITE}-{arch}.txt")
    if os.path.exists(cached):
        text = open(cached, encoding="utf-8").read()
        log(f"复用已缓存的软件包索引 {cached}")
    else:
        url = f"{ARCHIVE_BASE}/dists/{SUITE}/main/binary-{arch}/Packages.gz"
        log(f"下载软件包索引 {url}")
        with urllib.request.urlopen(url, timeout=900) as response:
            text = gzip.decompress(response.read()).decode("utf-8", "replace")
        with open(cached, "w", encoding="utf-8") as fh:
            fh.write(text)

    index: dict[str, dict[str, str]] = {}
    for block in text.split("\n\n"):
        if not block.strip():
            continue
        entry: dict[str, str] = {}
        for line in block.split("\n"):
            if line.startswith(" ") or ":" not in line:
                continue
            key, value = line.split(":", 1)
            entry[key.strip()] = value.strip()
        name = entry.get("Package")
        if name:
            index.setdefault(name, entry)
    return index


def extract_deb(deb_path: str, dest: str) -> None:
    """解包 .deb。优先用 dpkg-deb，回退到内置的 ar + tar 实现。"""
    if shutil.which("dpkg-deb"):
        subprocess.run(["dpkg-deb", "-x", deb_path, dest], check=True)
        return

    with open(deb_path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"!<arch>\n":
        raise RuntimeError(f"{deb_path} 不是合法的 ar 归档")

    pos = 8
    while pos + 60 <= len(data):
        header = data[pos:pos + 60]
        name = header[0:16].decode("ascii").strip()
        size = int(header[48:58].decode("ascii").strip())
        pos += 60
        body = data[pos:pos + size]
        pos += size + (size % 2)
        if name.startswith("data.tar"):
            with tarfile.open(fileobj=io.BytesIO(body)) as archive:
                archive.extractall(dest, filter="data")
            return
    raise RuntimeError(f"{deb_path} 中未找到 data.tar")


def prune(root: str) -> None:
    for rel in PRUNE_DIRS:
        shutil.rmtree(os.path.join(root, rel), ignore_errors=True)
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(PRUNE_SUFFIXES):
                os.remove(os.path.join(dirpath, name))


def main() -> int:
    parser = argparse.ArgumentParser(description="获取随套件分发的 Perl 运行时")
    parser.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    parser.add_argument("--out", required=True, help="输出目录，最终产出 <out>/perl-runtime")
    parser.add_argument("--cache", default=".cache/perl-debs", help="软件包缓存目录")
    args = parser.parse_args()

    index = load_index(args.arch, args.cache)

    runtime_root = os.path.join(args.out, "perl-runtime")
    shutil.rmtree(runtime_root, ignore_errors=True)
    os.makedirs(runtime_root, exist_ok=True)

    for package in REQUIRED_PACKAGES:
        entry = index.get(package)
        if entry is None:
            log(f"错误：索引中找不到软件包 {package}")
            return 1
        filename = entry["Filename"]
        local = os.path.join(args.cache, os.path.basename(filename))
        if not os.path.exists(local):
            url = f"{ARCHIVE_BASE}/{filename}"
            log(f"下载 {package} {entry.get('Version', '')}")
            with urllib.request.urlopen(url, timeout=600) as response, open(local, "wb") as fh:
                shutil.copyfileobj(response, fh)
        else:
            log(f"复用缓存中的 {package} {entry.get('Version', '')}")
        extract_deb(local, runtime_root)

    prune(runtime_root)

    perl_bin = os.path.join(runtime_root, "usr", "bin", "perl")
    if not os.path.exists(perl_bin):
        log(f"错误：解包结果中缺少 {perl_bin}")
        return 1
    os.chmod(perl_bin, 0o755)

    total = sum(
        os.path.getsize(os.path.join(dirpath, name))
        for dirpath, _dirs, files in os.walk(runtime_root)
        for name in files
    )
    log(f"完成：{runtime_root}（{total / 1024 / 1024:.1f} MiB）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
