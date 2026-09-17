#!/usr/bin/env python3
"""校验随套件分发的所有 ELF 文件所要求的 glibc 版本上限。

背景：套件面向群晖 DSM 7.x 与威联通 QTS 5.x，这些系统的 glibc 版本普遍偏旧
（例如 DSM 7.1 仅为 2.26）。如果随包二进制要求了更高的 GLIBC 符号版本，
应用在设备上会以 "version `GLIBC_2.34' not found" 直接启动失败。

因此打包流程把这条约束固化成一道闸门：任何超出基线的二进制都会让构建失败，
而不是等到用户安装后才发现。

用法：
    verify-glibc.py --max 2.26 <文件或目录> [<文件或目录> ...]

退出码：0 通过；1 存在超限文件；2 用法错误。
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

ELF_MAGIC = b"\x7fELF"


def _version_key(version: str) -> tuple[int, ...]:
    """把 GLIBC_2.26 这样的符号版本转成可比较的元组。"""
    body = version.split("_", 1)[1]
    parts: list[int] = []
    for chunk in body.split("."):
        digits = "".join(c for c in chunk if c.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts)


def required_glibc_versions(path: str) -> list[str] | None:
    """解析 .gnu.version_r，返回 libc.so.6 所需的版本符号列表。

    非 ELF、静态链接（无 .gnu.version_r）、或未依赖 libc 时返回 None。
    """
    with open(path, "rb") as fh:
        data = fh.read()

    if data[:4] != ELF_MAGIC:
        return None
    if data[4] != 2:
        # 仅处理 64 位 ELF：套件只面向 x86_64 与 aarch64
        return None

    endian = "<" if data[5] == 1 else ">"

    e_shoff, = struct.unpack_from(f"{endian}Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(f"{endian}HHH", data, 0x3A)
    if e_shoff == 0 or e_shnum == 0:
        return None

    sections: list[tuple[int, int, int]] = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, _typ, _flags, _addr, offset, size, _link, _info, _align, _ent = struct.unpack_from(
            f"{endian}IIQQQQIIQQ", data, off
        )
        sections.append((name, offset, size))

    if e_shstrndx >= len(sections):
        return None
    shstr_off = sections[e_shstrndx][1]

    def section_name(name_off: int) -> str:
        term = data.index(b"\x00", shstr_off + name_off)
        return data[shstr_off + name_off:term].decode("ascii", "replace")

    by_name: dict[str, tuple[int, int, int]] = {}
    for section in sections:
        by_name.setdefault(section_name(section[0]), section)

    version_r = by_name.get(".gnu.version_r")
    dynstr = by_name.get(".dynstr")
    if version_r is None or dynstr is None:
        return None

    def dynstr_at(offset: int) -> str:
        term = data.index(b"\x00", dynstr[1] + offset)
        return data[dynstr[1] + offset:term].decode("ascii", "replace")

    found: list[str] = []
    pos, end = version_r[1], version_r[1] + version_r[2]
    while pos < end:
        _ver, count, file_off, aux_off, next_off = struct.unpack_from(f"{endian}HHIII", data, pos)
        libname = dynstr_at(file_off)
        aux = pos + aux_off
        for _ in range(count):
            _hash, _flags, _other, name_off, aux_next = struct.unpack_from(f"{endian}IHHII", data, aux)
            if libname == "libc.so.6":
                name = dynstr_at(name_off)
                if name.startswith("GLIBC_"):
                    found.append(name)
            if aux_next == 0:
                break
            aux += aux_next
        if next_off == 0:
            break
        pos += next_off

    return found or None


def iter_elf_files(paths: list[str]):
    for path in paths:
        if os.path.isfile(path):
            yield path
            continue
        for root, _dirs, files in os.walk(path):
            for name in files:
                candidate = os.path.join(root, name)
                if os.path.islink(candidate):
                    continue
                try:
                    with open(candidate, "rb") as fh:
                        if fh.read(4) != ELF_MAGIC:
                            continue
                except OSError:
                    continue
                yield candidate


def main() -> int:
    parser = argparse.ArgumentParser(description="校验 ELF 文件的 glibc 版本上限")
    parser.add_argument("--max", required=True, help="允许的最高 glibc 版本，例如 2.26")
    parser.add_argument("paths", nargs="+", help="待检查的文件或目录")
    args = parser.parse_args()

    try:
        baseline = _version_key(f"GLIBC_{args.max}")
    except (IndexError, ValueError):
        print(f"无效的 --max 取值: {args.max}", file=sys.stderr)
        return 2

    worst_version: str | None = None
    worst_path: str | None = None
    violations: list[tuple[str, str]] = []
    checked = 0

    for path in iter_elf_files(args.paths):
        try:
            versions = required_glibc_versions(path)
        except (OSError, struct.error, ValueError):
            continue
        checked += 1
        if not versions:
            continue

        top = max(versions, key=_version_key)
        if worst_version is None or _version_key(top) > _version_key(worst_version):
            worst_version, worst_path = top, path
        if _version_key(top) > baseline:
            violations.append((path, top))

    print(f"已检查 {checked} 个 ELF 文件，基线 glibc {args.max}")
    if worst_version is not None:
        rel = os.path.relpath(worst_path or "", os.getcwd())
        print(f"最高需求: {worst_version} ({rel})")
    else:
        print("未发现对 glibc 的动态依赖（静态链接）")

    if violations:
        print()
        for path, version in violations:
            print(f"::error file={path}::要求 {version}，超出基线 glibc {args.max}")
        print(f"\n共 {len(violations)} 个文件超出基线，构建中止。")
        return 1

    print("全部符合基线要求。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
