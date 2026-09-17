#!/bin/sh
# Xiaomi Album Syncer —— 套件通用启动脚本
#
# 由群晖 start-stop-status 与威联通 service 脚本调用，负责准备好运行环境后
# 以 exec 方式把当前进程替换为应用进程，因此 PID 与调用方记录的一致，
# 停止套件时可以直接按 PID 结束。
#
# 入参环境变量：
#   XAS_ROOT  载荷根目录，需包含 app.jar / jre / exiftool
#   XAS_DATA  持久化数据目录
#   XAS_HOME  应用 home 目录，缺省为 ${XAS_DATA}/home
#
# 可选：在 ${XAS_DATA}/xas.env 中覆盖默认配置，例如
#   SERVER_PORT=18080
#   JAVA_CAPACITY_OPTS="-Xmx1g -XX:SoftMaxHeapSize=768m"
#   WEBAUTHN_RP_ID=nas.example.com
set -u

XAS_ROOT="${XAS_ROOT:?XAS_ROOT is required}"
XAS_DATA="${XAS_DATA:?XAS_DATA is required}"
XAS_HOME="${XAS_HOME:-${XAS_DATA}/home}"

XAS_JAVA_OPTS="${XAS_JAVA_OPTS:-}"
JAVA_CAPACITY_OPTS="${JAVA_CAPACITY_OPTS:--Xmx512m -XX:SoftMaxHeapSize=384m}"
SERVER_PORT="${SERVER_PORT:-8080}"

XAS_CONF="${XAS_DATA}/xas.env"
if [ -f "${XAS_CONF}" ]; then
    # shellcheck disable=SC1090
    . "${XAS_CONF}"
fi

mkdir -p "${XAS_DATA}/db" "${XAS_DATA}/logs" "${XAS_HOME}"
TMPDIR="${TMPDIR:-${XAS_DATA}/tmp}"
mkdir -p "${TMPDIR}"
export TMPDIR

# 套件内置的 ExifTool 优先于系统版本；应用默认配置里 exifToolPath 就是裸命令名
PATH="${XAS_ROOT}/exiftool/bin:${PATH}"
export PATH

# 与 Docker 镜像保持一致：限制 glibc arena，降低多线程下的 native 内存碎片
MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
export MALLOC_ARENA_MAX

export HOME="${XAS_HOME}"
export SERVER_PORT
export APP_DB_PATH="${APP_DB_PATH:-${XAS_DATA}/db/xiaomialbumsyncer.db}"

JAVA_BASE_OPTS="-XX:+UseG1GC \
  -XX:G1PeriodicGCInterval=60000 \
  -XX:-G1PeriodicGCInvokesConcurrent \
  -XX:G1PeriodicGCSystemLoadThreshold=0 \
  -XX:MaxHeapFreeRatio=20 \
  -XX:MinHeapFreeRatio=5 \
  -XX:TrimNativeHeapInterval=60000 \
  -XX:+UseCompactObjectHeaders \
  -XX:TieredStopAtLevel=1 \
  -XX:ReservedCodeCacheSize=48m \
  --enable-native-access=ALL-UNNAMED"

cd "${XAS_DATA}"
# shellcheck disable=SC2086
exec "${XAS_ROOT}/jre/bin/java" ${JAVA_BASE_OPTS} ${JAVA_CAPACITY_OPTS} ${XAS_JAVA_OPTS} \
    -jar "${XAS_ROOT}/app.jar"
