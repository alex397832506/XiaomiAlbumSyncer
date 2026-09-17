#!/bin/sh
# 威联通套件服务脚本。
#
# qinstall.sh 会把它链接到 /etc/init.d/xiaomi-album-syncer.sh，
# 并进一步链接到 /etc/rcS.d/QS101xiaomi-album-syncer，于是开机自启、
# App Center 的启动/停止按钮以及卸载流程都会调用到这里。
QPKG_NAME="xiaomi-album-syncer"
QPKG_CONF="/etc/config/qpkg.conf"

QPKG_DIR="$(/sbin/getcfg "${QPKG_NAME}" Install_Path -f "${QPKG_CONF}")"
if [ -z "${QPKG_DIR}" ] || [ ! -d "${QPKG_DIR}" ]; then
    echo "${QPKG_NAME}: 无法从 ${QPKG_CONF} 读取 Install_Path" >&2
    exit 1
fi

PID_FILE="${QPKG_DIR}/data/xas.pid"
LOG_FILE="${QPKG_DIR}/data/xas.log"

XAS_ROOT="${QPKG_DIR}"
XAS_DATA="${QPKG_DIR}/data"
XAS_HOME="${QPKG_DIR}/home"
export XAS_ROOT XAS_DATA XAS_HOME

is_running() {
    [ -f "${PID_FILE}" ] || return 1
    PID="$(cat "${PID_FILE}" 2>/dev/null)"
    [ -n "${PID}" ] || return 1
    kill -0 "${PID}" 2>/dev/null
}

start_service() {
    mkdir -p "${XAS_DATA}" "${XAS_HOME}"

    if is_running; then
        return 0
    fi
    rm -f "${PID_FILE}"

    echo "----- $(date '+%Y-%m-%d %H:%M:%S') starting ${QPKG_NAME} -----" >> "${LOG_FILE}"
    nohup "${QPKG_DIR}/bin/xas-launch.sh" >> "${LOG_FILE}" 2>&1 &
    PID=$!
    echo "${PID}" > "${PID_FILE}"

    i=0
    while [ "${i}" -lt 5 ]; do
        kill -0 "${PID}" 2>/dev/null || {
            echo "${QPKG_NAME} 启动过程中退出，详见 ${LOG_FILE}" >&2
            rm -f "${PID_FILE}"
            return 1
        }
        i=$((i + 1))
        sleep 1
    done
    return 0
}

stop_service() {
    if [ -f "${PID_FILE}" ]; then
        PID="$(cat "${PID_FILE}" 2>/dev/null)"
        if [ -n "${PID}" ]; then
            kill "${PID}" 2>/dev/null
            i=0
            while kill -0 "${PID}" 2>/dev/null && [ "${i}" -lt 30 ]; do
                i=$((i + 1))
                sleep 1
            done
            kill -9 "${PID}" 2>/dev/null
        fi
        rm -f "${PID_FILE}"
    fi
    pkill -f "${QPKG_DIR}/app.jar" 2>/dev/null
    return 0
}

case "$1" in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        start_service
        ;;
    status)
        if is_running; then
            echo "${QPKG_NAME} is running"
            exit 0
        fi
        echo "${QPKG_NAME} is not running"
        exit 1
        ;;
    *)
        echo "usage: $0 {start|stop|restart|status}" >&2
        exit 1
        ;;
esac
