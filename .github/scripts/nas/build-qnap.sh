#!/usr/bin/env bash
#
# 组装威联通 QTS 套件（.qpkg）。
#
# QPKG 是一个自解压文件，自前向后依次为：
#   [自解压 shell 头] [control.tar] [data.tar.gz] [100 字节尾部元数据]
#
#   * 头部负责定位安装卷、校验架构、用 dd+tar 取出后面两段归档，最后执行 qinstall.sh
#   * control.tar 是未压缩 tar，内含一个 gzip 过的 control.tar.gz，
#     存放 qpkg.cfg / package_routines / qinstall.sh / built_info
#   * data.tar.gz 解包到套件安装目录，是应用真正的载荷
#   * 尾部 100 字节为 MODEL(10) + RESERVED(50) + NAME(20) + VERSION(10) + "QNAPQPKG  "
#
# 这一结构与官方 QDK 的 qbuild 完全对齐，因此 QTS 可以原样识别。
# qinstall.sh 直接从 QNAP 官方仓库拉取，不在本仓库中内置第三方安装器。
#
# 用法：
#   build-qnap.sh --version <版本> --arch <x86_64|arm_64> --payload <目录> --out <目录>
#
# 环境变量：
#   QDK_REF             拉取 qinstall.sh 的 git 引用，默认 master
#   QDK_QINSTALL_SHA256 若设置则校验 qinstall.sh 的 sha256，用于固定依赖
#   GLIBC_BASELINE      允许的最高 glibc 版本，默认 2.26
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/packaging/qnap"

PKG_NAME="xiaomi-album-syncer"
QPKG_DISPLAY_NAME="Xiaomi Album Syncer"
QPKG_VER=""
VERSION=""
ARCH=""
PAYLOAD=""
OUT_DIR=""
QDK_REF="${QDK_REF:-master}"
QDK_QINSTALL_SHA256="${QDK_QINSTALL_SHA256:-}"
GLIBC_BASELINE="${GLIBC_BASELINE:-2.26}"

usage() {
    echo "用法: $0 --version <版本> --arch <x86_64|arm_64> --payload <目录> --out <目录>" >&2
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
    x86_64) CPU_ARCH_PATTERN="x86_64" ;;
    arm_64) CPU_ARCH_PATTERN="aarch64" ;;
    *) echo "威联通架构只支持 x86_64 或 arm_64，收到: ${ARCH}" >&2; exit 2 ;;
esac

[ -d "${PAYLOAD}" ] || { echo "载荷目录不存在: ${PAYLOAD}" >&2; exit 1; }

# QPKG_VER 限长 10 字符且不含空格。预发布版本形如 0.18.0-rc.1 有 11 字符，
# 先去掉连字符（0.18.0rc.1 恰好 10 字符），仍然超长再截断。
QPKG_VER="$(printf '%s' "${VERSION}" | tr -d ' ')"
if [ "${#QPKG_VER}" -gt 10 ]; then
    SHORTENED="$(printf '%s' "${QPKG_VER}" | tr -d '-')"
    echo "==> QPKG_VER \"${QPKG_VER}\" 超过 10 字符，改写为 \"${SHORTENED}\""
    QPKG_VER="${SHORTENED}"
fi
if [ "${#QPKG_VER}" -gt 10 ]; then
    QPKG_VER="$(printf '%s' "${QPKG_VER}" | cut -c1-10)"
    echo "==> 仍然超长，截断为 \"${QPKG_VER}\""
fi

echo "==> 校验载荷 glibc 基线"
python3 "${SCRIPT_DIR}/verify-glibc.py" --max "${GLIBC_BASELINE}" "${PAYLOAD}"

OUT_DIR="$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> 获取 QNAP 官方 qinstall.sh (${QDK_REF})"
QINSTALL="${WORK_DIR}/qinstall.sh"
QINSTALL_URL="https://raw.githubusercontent.com/qnap-dev/QDK/${QDK_REF}/shared/scripts/qinstall.sh"
if ! curl -fsSL --retry 3 --retry-all-errors -o "${QINSTALL}" "${QINSTALL_URL}"; then
    echo "下载 ${QINSTALL_URL} 失败，请检查网络或调整 QDK_REF。" >&2
    exit 1
fi
if [ -n "${QDK_QINSTALL_SHA256}" ]; then
    ACTUAL_SHA256="$(sha256sum "${QINSTALL}" | cut -d' ' -f1)"
    if [ "${ACTUAL_SHA256}" != "${QDK_QINSTALL_SHA256}" ]; then
        echo "qinstall.sh 校验失败：期望 ${QDK_QINSTALL_SHA256}，实际 ${ACTUAL_SHA256}" >&2
        exit 1
    fi
    echo "    sha256 校验通过"
else
    echo "    sha256: $(sha256sum "${QINSTALL}" | cut -d' ' -f1)（未做固定校验）"
fi

echo "==> 准备 control 包"
CONTROL_DIR="${WORK_DIR}/control"
mkdir -p "${CONTROL_DIR}"
# 同样只把键值对写进产物，模板注释留在仓库里
sed -e "s/@VERSION@/${QPKG_VER}/g" \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' \
    "${TEMPLATE_DIR}/qpkg.cfg" > "${CONTROL_DIR}/qpkg.cfg"
install -m 0644 "${TEMPLATE_DIR}/package_routines" "${CONTROL_DIR}/package_routines"
install -m 0755 "${QINSTALL}" "${CONTROL_DIR}/qinstall.sh"
printf 'time = %s\n' "$(date +%Y%m%d)" > "${CONTROL_DIR}/built_info"

# control.tar：未压缩 tar，内含一个 gzip 过的 control.tar.gz
tar --owner=0 --group=0 --numeric-owner -czf "${WORK_DIR}/control.tar.gz" -C "${CONTROL_DIR}" .
tar --owner=0 --group=0 --numeric-owner -cf "${WORK_DIR}/control.tar" -C "${WORK_DIR}" control.tar.gz
CTRL_LEN="$(stat -c %s "${WORK_DIR}/control.tar")"

echo "==> 准备 data 包"
DATA_DIR="${WORK_DIR}/data"
mkdir -p "${DATA_DIR}/bin" "${DATA_DIR}/data"
cp -a "${PAYLOAD}/." "${DATA_DIR}/"
install -m 0755 "${TEMPLATE_DIR}/shared/${PKG_NAME}.sh" "${DATA_DIR}/${PKG_NAME}.sh"

ICON_SRC="${REPO_ROOT}/static/xiaomi-album-syncer-logo.png"
if command -v magick >/dev/null 2>&1; then
    IM="magick"
elif command -v convert >/dev/null 2>&1; then
    IM="convert"
else
    echo "需要 ImageMagick（magick 或 convert）来生成套件图标" >&2
    exit 1
fi

# qinstall.sh 的 copy_qpkg_icons 会读取安装目录下的这三个文件
make_icon() {
    local size="$1" gray="$2" dest="$3"
    if [ "${gray}" = "gray" ]; then
        "${IM}" "${ICON_SRC}" -background none -resize "${size}x${size}" -gravity center \
            -extent "${size}x${size}" -colorspace Gray -fill '#B4B2A9' -colorize 35% "${dest}"
    else
        "${IM}" "${ICON_SRC}" -background none -resize "${size}x${size}" -gravity center -extent "${size}x${size}" "${dest}"
    fi
}
make_icon 64 color "${DATA_DIR}/.qpkg_icon.gif"
make_icon 80 color "${DATA_DIR}/.qpkg_icon_80.gif"
make_icon 64 gray "${DATA_DIR}/.qpkg_icon_gray.gif"

tar --owner=0 --group=0 --numeric-owner -czf "${WORK_DIR}/data.tar.gz" -C "${DATA_DIR}" .
DATA_LEN="$(stat -c %s "${WORK_DIR}/data.tar.gz")"
DATA_BLOCKS=$(((DATA_LEN + 1023) / 1024))

echo "==> 生成自解压头"
HEADER="${WORK_DIR}/header.sh"
TPL_HEADER="${TEMPLATE_DIR}/header.sh.in"
sed \
    -e "s/@QPKG_NAME@/${PKG_NAME}/g" \
    -e "s/@QPKG_DISPLAY_NAME@/${QPKG_DISPLAY_NAME}/g" \
    -e "s/@QPKG_VER@/${QPKG_VER}/g" \
    -e "s/@CPU_ARCH_PATTERN@/${CPU_ARCH_PATTERN}/g" \
    -e "s/@CTRL_LEN@/${CTRL_LEN}/g" \
    -e "s/@DATA_LEN@/${DATA_LEN}/g" \
    -e "s/@DATA_BLOCKS@/${DATA_BLOCKS}/g" \
    "${TPL_HEADER}" > "${HEADER}"

# script_len 用等宽占位符，替换后文件长度不变，避免出现自指的长度计算
if ! grep -q 'script_len=0000000000' "${HEADER}"; then
    echo "头部模板缺少 script_len 等宽占位符" >&2
    exit 1
fi
SCRIPT_LEN="$(stat -c %s "${HEADER}")"
printf -v SCRIPT_LEN_PADDED '%010d' "${SCRIPT_LEN}"
sed -i "s/script_len=0000000000/script_len=${SCRIPT_LEN_PADDED}/" "${HEADER}"
if [ "$(stat -c %s "${HEADER}")" != "${SCRIPT_LEN}" ]; then
    echo "替换 script_len 后头部长度发生变化" >&2
    exit 1
fi
if [ "${SCRIPT_LEN}" -ge 10000000000 ]; then
    echo "头部长度 ${SCRIPT_LEN} 超出 10 位占位符容量" >&2
    exit 1
fi

echo "==> 拼接 QPKG"
QPKG_NAME_OUT="${PKG_NAME}-${ARCH}-${QPKG_VER}.qpkg"
QPKG_PATH="${OUT_DIR}/${QPKG_NAME_OUT}"

cat "${HEADER}" "${WORK_DIR}/control.tar" "${WORK_DIR}/data.tar.gz" > "${QPKG_PATH}"

# 尾部 100 字节：MODEL(10) + RESERVED(50) + NAME(20) + VERSION(10) + FLAG(10)
TAIL="$(printf '%-10s%50s%-20s%-10s%s' "" "" "${PKG_NAME}" "${QPKG_VER}" "QNAPQPKG  ")"
if [ "${#TAIL}" -ne 100 ]; then
    echo "尾部元数据长度应为 100，实际 ${#TAIL}" >&2
    exit 1
fi
printf '%s' "${TAIL}" >> "${QPKG_PATH}"

if ! /bin/sh -n "${HEADER}"; then
    echo "生成的头部脚本存在语法错误" >&2
    exit 1
fi
chmod 0755 "${QPKG_PATH}"

echo "==> 校验产物结构"
FINAL_LEN="$(stat -c %s "${QPKG_PATH}")"
EXPECTED_LEN=$((SCRIPT_LEN + CTRL_LEN + DATA_LEN + 100))
if [ "${FINAL_LEN}" -ne "${EXPECTED_LEN}" ]; then
    echo "产物长度不符：期望 ${EXPECTED_LEN}，实际 ${FINAL_LEN}" >&2
    exit 1
fi
TAIL_CHECK="$(tail -c 10 "${QPKG_PATH}")"
if [ "${TAIL_CHECK}" != "QNAPQPKG  " ]; then
    echo "尾部标记校验失败：${TAIL_CHECK}" >&2
    exit 1
fi

QPKG_SIZE="$(du -m "${QPKG_PATH}" | cut -f1)"
echo "==> 完成：${QPKG_PATH} (${QPKG_SIZE} MiB, control ${CTRL_LEN} B, data ${DATA_LEN} B)"
