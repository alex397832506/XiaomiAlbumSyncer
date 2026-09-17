#!/usr/bin/env bash
#
# 组装群晖 DSM 7 套件（.spk）。
#
# SPK 本质上就是一个未压缩的 tar 包，成员如下（INFO 必须排在最前）：
#   INFO                    套件元信息
#   LICENSE
#   PACKAGE_ICON.PNG        64/72 像素图标
#   PACKAGE_ICON_256.PNG    256 像素图标
#   conf/privilege          运行身份声明
#   package.tgz             实际载荷（官方 toolkit 用的是 xz 压缩）
#   scripts/                生命周期脚本
#   ui/                     桌面入口（可选）
#
# 成员顺序与压缩方式对齐 Synology 官方 pkgscripts-ng 的 pkg_make_spk /
# pkg_make_package，避免依赖 ls 的排序行为。
#
# 用法：
#   build-synology.sh --version <版本> --arch <x86_64|armv8> --payload <目录> --out <目录>
#
# 环境变量：
#   DSM_UI=0            不生成 ui/ 桌面入口（默认 1）
#   GLIBC_BASELINE      允许的最高 glibc 版本，默认 2.26
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/packaging/synology"

PKG_NAME="xiaomi-album-syncer"
VERSION=""
ARCH=""
PAYLOAD=""
OUT_DIR=""
DSM_UI="${DSM_UI:-1}"
GLIBC_BASELINE="${GLIBC_BASELINE:-2.26}"

usage() {
    echo "用法: $0 --version <版本> --arch <x86_64|armv8> --payload <目录> --out <目录>" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version 需要一个取值}"; shift 2 ;;
        --arch) ARCH="${2:?--arch 需要一个取值}"; shift 2 ;;
        --payload) PAYLOAD="${2:?--payload 需要一个路径}"; shift 2 ;;
        --out) OUT_DIR="${2:?--out 需要一个路径}"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

[ -n "${VERSION}" ] || usage
[ -n "${ARCH}" ] || usage
[ -n "${PAYLOAD}" ] || usage
[ -n "${OUT_DIR}" ] || usage

case "${ARCH}" in
    x86_64 | armv8) ;;
    *) echo "群晖架构只支持 x86_64 或 armv8，收到: ${ARCH}" >&2; exit 2 ;;
esac

[ -d "${PAYLOAD}" ] || { echo "载荷目录不存在: ${PAYLOAD}" >&2; exit 1; }

echo "==> 校验载荷 glibc 基线"
python3 "${SCRIPT_DIR}/verify-glibc.py" --max "${GLIBC_BASELINE}" "${PAYLOAD}"

OUT_DIR="$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
STAGE="${WORK_DIR}/spk"
mkdir -p "${STAGE}"

echo "==> 渲染 INFO"
# 模板里的注释只服务于仓库维护者，产物中必须只保留键值对：
# DSM 官方 toolkit 生成的 INFO 不含注释，带上注释属于对格式的额外假设。
sed -e "s/@VERSION@/${VERSION}/g" \
    -e "s/@ARCH@/${ARCH}/g" \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' \
    "${TEMPLATE_DIR}/INFO" > "${STAGE}/INFO"

if [ "${DSM_UI}" = "0" ]; then
    echo "    DSM_UI=0，跳过桌面入口与 dsmappname"
    sed -i '/^dsmuidir=/d; /^dsmappname=/d' "${STAGE}/INFO"
fi

if ! grep -q '^os_min_ver="7\.0-40000"' "${STAGE}/INFO"; then
    echo "INFO 中的 os_min_ver 必须为 7.0-40000，这是 DSM 7 套件的硬性下限" >&2
    exit 1
fi

echo "==> 生成图标"
ICON_SRC="${REPO_ROOT}/static/xiaomi-album-syncer-logo.png"
[ -f "${ICON_SRC}" ] || { echo "找不到图标源文件: ${ICON_SRC}" >&2; exit 1; }

if command -v magick >/dev/null 2>&1; then
    IM="magick"
elif command -v convert >/dev/null 2>&1; then
    IM="convert"
else
    echo "需要 ImageMagick（magick 或 convert）来生成套件图标" >&2
    exit 1
fi

# 源图不是正方形，先等比缩放再居中裁成正方形画布
make_icon() {
    local size="$1" dest="$2"
    mkdir -p "$(dirname "${dest}")"
    "${IM}" "${ICON_SRC}" -background none -resize "${size}x${size}" -gravity center -extent "${size}x${size}" "${dest}"
}

make_icon 72 "${STAGE}/PACKAGE_ICON.PNG"
make_icon 256 "${STAGE}/PACKAGE_ICON_256.PNG"

INCLUDE_UI=""
if [ "${DSM_UI}" != "0" ]; then
    install -d "${STAGE}/ui/images"
    install -m 0644 "${TEMPLATE_DIR}/ui/config" "${STAGE}/ui/config"
    for size in 16 24 32 48 64 72 256; do
        make_icon "${size}" "${STAGE}/ui/images/icon_${size}.png"
    done
    INCLUDE_UI="ui"
fi

echo "==> 安装生命周期脚本"
install -d "${STAGE}/scripts" "${STAGE}/conf"
for script in preinst postinst preuninst postuninst start-stop-status; do
    install -m 0755 "${TEMPLATE_DIR}/scripts/${script}" "${STAGE}/scripts/${script}"
done
install -m 0644 "${TEMPLATE_DIR}/conf/privilege" "${STAGE}/conf/privilege"
install -m 0644 "${REPO_ROOT}/LICENSE" "${STAGE}/LICENSE"

echo "==> 打包 package.tgz（xz 压缩，与官方 pkg_make_package 一致）"
tar --owner=0 --group=0 --numeric-owner -cJf "${STAGE}/package.tgz" -C "${PAYLOAD}" .

SPK_NAME="${PKG_NAME}-${ARCH}-${VERSION}.spk"
SPK_PATH="${OUT_DIR}/${SPK_NAME}"

# INFO 必须位于 tar 最前，因此显式列出成员顺序而非依赖 ls 的排序
MEMBERS=(INFO LICENSE PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG conf package.tgz scripts)
if [ -n "${INCLUDE_UI}" ]; then
    MEMBERS+=("${INCLUDE_UI}")
fi

echo "==> 生成 ${SPK_NAME}"
tar --owner=0 --group=0 --numeric-owner -cf "${SPK_PATH}" -C "${STAGE}" "${MEMBERS[@]}"

echo "==> 校验产物结构"
FIRST_MEMBER="$(tar -tf "${SPK_PATH}" | head -n 1)"
if [ "${FIRST_MEMBER}" != "INFO" ]; then
    echo "SPK 首个成员应为 INFO，实际为 ${FIRST_MEMBER}" >&2
    exit 1
fi
tar -tf "${SPK_PATH}"

SPK_SIZE="$(du -m "${SPK_PATH}" | cut -f1)"
echo "==> 完成：${SPK_PATH} (${SPK_SIZE} MiB)"
