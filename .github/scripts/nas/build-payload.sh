#!/usr/bin/env bash
#
# 组装群晖 SPK 与威联通 QPKG 共用的载荷目录。
#
# 产出结构：
#   <out>/app.jar                应用主程序
#   <out>/jre/                   jlink 裁剪出的运行时（Temurin，glibc 2.17 基线）
#   <out>/exiftool/              内置 ExifTool + Perl 运行时（可选）
#   <out>/bin/xas-launch.sh      套件启停脚本调用的入口
#   <out>/LICENSE
#
# 为什么用 JAR + 内置 JRE 而不是原生二进制：
# CI 在 ubuntu-24.04(glibc 2.39) 上产出的 GraalVM 原生镜像要求 GLIBC_2.34，
# 而群晖 DSM 7.0/7.1 只有 glibc 2.26、威联通 QTS 5.x 更低，会在设备上直接
# 报 "version `GLIBC_2.34' not found" 起不来。Temurin 的运行时基线是
# glibc 2.17，可以覆盖全部目标机型。
#
# 用法：
#   build-payload.sh --arch x86_64|arm64 --jar <app.jar> --out <目录> [--exiftool-dist <目录>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ARCH=""
JAR=""
OUT_DIR=""
EXIFTOOL_DIST=""
GLIBC_BASELINE="${GLIBC_BASELINE:-2.26}"
SMOKE_PORT="${SMOKE_PORT:-18080}"

# jlink 裁剪用的模块集合。刻意取得偏宽松：漏掉模块会导致运行时才炸，
# 而多带几个模块只是几 MB 的代价。其中 jdk.crypto.ec 是访问小米云 HTTPS 所必需，
# jdk.charsets 与 jdk.localedata 用于中文环境下的字符集与本地化。
JLINK_MODULES="java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,\
java.logging,java.management,java.naming,java.net.http,java.prefs,java.rmi,java.scripting,\
java.security.jgss,java.security.sasl,java.sql,java.sql.rowset,java.transaction.xa,java.xml,\
jdk.charsets,jdk.crypto.cryptoki,jdk.crypto.ec,jdk.localedata,jdk.management,jdk.naming.dns,\
jdk.unsupported,jdk.zipfs"

usage() {
    echo "用法: $0 --arch <x86_64|arm64> --jar <app.jar> --out <目录> [--exiftool-dist <目录>]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?--arch 需要一个取值}"; shift 2 ;;
        --jar) JAR="${2:?--jar 需要一个路径}"; shift 2 ;;
        --out) OUT_DIR="${2:?--out 需要一个路径}"; shift 2 ;;
        --exiftool-dist) EXIFTOOL_DIST="${2:?--exiftool-dist 需要一个路径}"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

[ -n "${ARCH}" ] || usage
[ -n "${JAR}" ] || usage
[ -n "${OUT_DIR}" ] || usage

[ -f "${JAR}" ] || { echo "找不到 JAR: ${JAR}" >&2; exit 1; }
[ -n "${JAVA_HOME:-}" ] || { echo "需要设置 JAVA_HOME 才能调用 jlink" >&2; exit 1; }
[ -x "${JAVA_HOME}/bin/jlink" ] || { echo "${JAVA_HOME}/bin/jlink 不存在，JAVA_HOME 需要指向 JDK" >&2; exit 1; }

OUT_DIR="$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)"
rm -rf "${OUT_DIR:?}/"*

echo "==> 生成运行时 jre/ (${ARCH})"
JLINK_ARGS=(
    --add-modules "${JLINK_MODULES}"
    --strip-debug
    --no-header-files
    --no-man-pages
    --output "${OUT_DIR}/jre"
)
# --compress=zip-N 是 JDK 21 起的写法。万一当前 JDK 不接受，退回不压缩，
# 只损失几 MB 体积，不让整个构建挂掉。
if "${JAVA_HOME}/bin/jlink" --compress=zip-6 "${JLINK_ARGS[@]}"; then
    echo "    已启用 zip-6 压缩"
else
    echo "    --compress=zip-6 未被当前 JDK 接受，改用不压缩输出" >&2
    rm -rf "${OUT_DIR}/jre"
    "${JAVA_HOME}/bin/jlink" "${JLINK_ARGS[@]}"
fi

echo "==> 放置 JAR 与入口脚本"
install -m 0644 "${JAR}" "${OUT_DIR}/app.jar"
mkdir -p "${OUT_DIR}/bin"
install -m 0755 "${REPO_ROOT}/packaging/common/bin/xas-launch.sh" "${OUT_DIR}/bin/xas-launch.sh"
install -m 0644 "${REPO_ROOT}/LICENSE" "${OUT_DIR}/LICENSE"

if [ -n "${EXIFTOOL_DIST}" ]; then
    [ -f "${EXIFTOOL_DIST}/bin/exiftool" ] || { echo "ExifTool 目录无效: ${EXIFTOOL_DIST}" >&2; exit 1; }
    echo "==> 合入内置 ExifTool"
    mkdir -p "${OUT_DIR}/exiftool"
    cp -a "${EXIFTOOL_DIST}/." "${OUT_DIR}/exiftool/"

    # actions/upload-artifact 与 download-artifact 不保留文件权限，ExifTool 运行时
    # 经 artifact 中转后会丢掉可执行位，这里必须显式恢复，否则套件里的 ExifTool
    # 无法被调用（应用执行 exiftool 时会直接报权限错误）。
    chmod 0755 "${OUT_DIR}/exiftool/bin/exiftool"
    for entry in "${OUT_DIR}/exiftool/perl-runtime/usr/bin/"*; do
        [ -f "${entry}" ] && chmod 0755 "${entry}"
    done
else
    echo "==> 未提供 ExifTool，套件将不包含 EXIF 处理能力"
fi

echo "==> 校验 glibc 基线"
VERIFY_PATHS=("${OUT_DIR}/jre")
[ -d "${OUT_DIR}/exiftool" ] && VERIFY_PATHS+=("${OUT_DIR}/exiftool")
python3 "${SCRIPT_DIR}/verify-glibc.py" --max "${GLIBC_BASELINE}" "${VERIFY_PATHS[@]}"

echo "==> 冒烟测试：确认运行时与应用都能跑起来"
"${OUT_DIR}/jre/bin/java" -version
if [ -f "${OUT_DIR}/exiftool/bin/exiftool" ]; then
    [ -x "${OUT_DIR}/exiftool/bin/exiftool" ] || { echo "ExifTool 入口缺少可执行位" >&2; exit 1; }
    echo "    exiftool -ver -> $("${OUT_DIR}/exiftool/bin/exiftool" -ver)"
fi

SMOKE_DATA="$(mktemp -d)"
SMOKE_LOG="$(mktemp)"
APP_PID=""
cleanup() {
    [ -n "${APP_PID}" ] && kill "${APP_PID}" 2>/dev/null || true
    sleep 1
    [ -n "${APP_PID}" ] && kill -9 "${APP_PID}" 2>/dev/null || true
    rm -rf "${SMOKE_DATA}" "${SMOKE_LOG}"
}
trap cleanup EXIT

XAS_ROOT="${OUT_DIR}" \
    XAS_DATA="${SMOKE_DATA}" \
    SERVER_PORT="${SMOKE_PORT}" \
    "${OUT_DIR}/bin/xas-launch.sh" > "${SMOKE_LOG}" 2>&1 &
APP_PID=$!

READY=0
for _ in $(seq 1 60); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        echo "应用进程在冒烟测试中提前退出，日志如下：" >&2
        cat "${SMOKE_LOG}" >&2
        exit 1
    fi
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${SMOKE_PORT}/" || true)"
    if [ -n "${CODE}" ] && [ "${CODE}" != "000" ]; then
        echo "    应用已在端口 ${SMOKE_PORT} 响应，HTTP ${CODE}"
        READY=1
        break
    fi
    sleep 1
done

if [ "${READY}" -ne 1 ]; then
    echo "应用在 60 秒内没有在端口 ${SMOKE_PORT} 上响应，日志如下：" >&2
    cat "${SMOKE_LOG}" >&2
    exit 1
fi

SIZE="$(du -sm "${OUT_DIR}" | cut -f1)"
echo "==> 完成：${OUT_DIR} (${SIZE} MiB)"
