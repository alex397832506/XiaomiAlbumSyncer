#!/usr/bin/env bash
#
# 组装随套件分发的 ExifTool。
#
# 产出目录结构（可整体搬迁到任意路径）：
#   <out>/bin/exiftool              包装脚本，应用通过 PATH 命中它
#   <out>/libexec/exiftool-impl     官方 exiftool 脚本本体
#   <out>/lib/Image/ExifTool/...    官方 Perl 模块
#   <out>/perl-runtime/...          Perl 解释器与核心模块
#
# 之所以要自带 Perl：群晖 DSM 默认不带 Perl，威联通各机型差异大；而 ExifTool
# 本身是 Perl 程序，应用的 EXIF 处理还会使用 -if 表达式与 -overwrite_original，
# 无法用其它语言的替代实现顶替。
#
# 用法：
#   build-exiftool-dist.sh --arch x86_64|x86_64 --out <目录>
#
# 可用环境变量：
#   EXIFTOOL_VERSION  ExifTool 版本，默认 13.57
#   GLIBC_BASELINE    允许的最高 glibc 版本，默认 2.26
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ARCH=""
OUT_DIR=""
EXIFTOOL_VERSION="${EXIFTOOL_VERSION:-13.57}"
GLIBC_BASELINE="${GLIBC_BASELINE:-2.26}"

usage() {
    echo "用法: $0 --arch <x86_64|arm64> --out <目录>" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?--arch 需要一个取值}"; shift 2 ;;
        --out) OUT_DIR="${2:?--out 需要一个路径}"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

[ -n "${ARCH}" ] || usage
[ -n "${OUT_DIR}" ] || usage

case "${ARCH}" in
    x86_64 | amd64) DEB_ARCH="amd64" ;;
    arm64 | aarch64) DEB_ARCH="arm64" ;;
    *) echo "不支持的架构: ${ARCH}" >&2; exit 2 ;;
esac

OUT_DIR="$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> 获取 Perl 运行时 (${DEB_ARCH})"
python3 "${SCRIPT_DIR}/fetch-perl-runtime.py" \
    --arch "${DEB_ARCH}" \
    --out "${OUT_DIR}" \
    --cache "${PERL_DEB_CACHE:-${REPO_ROOT}/.cache/perl-debs}"

echo "==> 下载 ExifTool ${EXIFTOOL_VERSION}"
ET_TARBALL="${WORK_DIR}/exiftool.tar.gz"
ET_URL="https://exiftool.org/Image-ExifTool-${EXIFTOOL_VERSION}.tar.gz"
if ! curl -fsSL --retry 3 --retry-all-errors -o "${ET_TARBALL}" "${ET_URL}"; then
    echo "下载 ${ET_URL} 失败。" >&2
    echo "请通过环境变量 EXIFTOOL_VERSION 指定一个可用版本，或检查网络。" >&2
    exit 1
fi

tar -xzf "${ET_TARBALL}" -C "${WORK_DIR}"
ET_SRC="${WORK_DIR}/Image-ExifTool-${EXIFTOOL_VERSION}"
if [ ! -f "${ET_SRC}/exiftool" ] || [ ! -d "${ET_SRC}/lib/Image/ExifTool" ]; then
    echo "ExifTool 发行包结构异常，缺少 exiftool 脚本或 lib/Image/ExifTool" >&2
    exit 1
fi

echo "==> 组装 ExifTool 目录结构"
rm -rf "${OUT_DIR}/lib" "${OUT_DIR}/libexec" "${OUT_DIR}/bin"
mkdir -p "${OUT_DIR}/lib" "${OUT_DIR}/libexec" "${OUT_DIR}/bin"
cp -a "${ET_SRC}/lib/." "${OUT_DIR}/lib/"
install -m 0755 "${ET_SRC}/exiftool" "${OUT_DIR}/libexec/exiftool-impl"
install -m 0755 "${REPO_ROOT}/packaging/common/exiftool-wrapper.sh" "${OUT_DIR}/bin/exiftool"

echo "==> 校验 glibc 基线"
python3 "${SCRIPT_DIR}/verify-glibc.py" --max "${GLIBC_BASELINE}" "${OUT_DIR}"

echo "==> 冒烟测试：确认 Perl 与 ExifTool 能真正跑起来"
BUNDLED_VERSION="$("${OUT_DIR}/bin/exiftool" -ver)"
echo "    exiftool -ver -> ${BUNDLED_VERSION}"
[ -n "${BUNDLED_VERSION}" ] || {
    echo "exiftool -ver 没有输出，构建中止" >&2
    exit 1
}

# 用一张最小可解析的 JPEG 走一遍真实解析路径，覆盖 Perl XS 模块与 ExifTool 模块加载。
SMOKE_JPEG="${WORK_DIR}/smoke.jpg"
printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${SMOKE_JPEG}"
SMOKE_JSON="$("${OUT_DIR}/bin/exiftool" -j -G "${SMOKE_JPEG}")"
case "${SMOKE_JSON}" in
    *JFIFVersion*) echo "    -j -G 解析正常" ;;
    *)
        echo "ExifTool 冒烟测试未返回预期结果：" >&2
        echo "${SMOKE_JSON}" >&2
        exit 1
        ;;
esac

SIZE="$(du -sm "${OUT_DIR}" | cut -f1)"
echo "==> 完成：${OUT_DIR} (${SIZE} MiB, ExifTool ${BUNDLED_VERSION}, Perl ${DEB_ARCH})"
