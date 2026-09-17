#!/usr/bin/env bash
#
# 组装飞牛 fnOS 套件（.fpk）。
#
# 飞牛的应用包由官方工具 fnpack 生成，且应用本身必须以容器方式运行：
# fnOS 不会在设备上现场构建镜像，因此 compose 里引用的镜像标签必须与
# CD 阶段推送到 Docker Hub 的标签完全一致。标签不一致会在用户安装时
# 表现为 manifest unknown / EOF，这一点在构建期就用 docker manifest inspect 拦下来。
#
# 用法：
#   build-fnos.sh --version <版本> --image <镜像仓库> --image-tag <标签> --out <目录>
#
# 环境变量：
#   FNPACK_VERSION     fnpack 版本，默认 1.2.3
#   SKIP_IMAGE_CHECK=1 跳过镜像存在性校验（仅用于本地调试）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/packaging/fnos"

APP_NAME="xiaomi-album-syncer"
VERSION=""
IMAGE=""
IMAGE_TAG=""
OUT_DIR=""
FNPACK_VERSION="${FNPACK_VERSION:-1.2.3}"
SKIP_IMAGE_CHECK="${SKIP_IMAGE_CHECK:-0}"

usage() {
    echo "用法: $0 --version <版本> --image <镜像仓库> --image-tag <标签> --out <目录>" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version 需要一个取值}"; shift 2 ;;
        --image) IMAGE="${2:?--image 需要一个取值}"; shift 2 ;;
        --image-tag) IMAGE_TAG="${2:?--image-tag 需要一个取值}"; shift 2 ;;
        --out) OUT_DIR="${2:?--out 需要一个路径}"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

[ -n "${VERSION}" ] || usage
[ -n "${IMAGE}" ] || usage
[ -n "${IMAGE_TAG}" ] || usage
[ -n "${OUT_DIR}" ] || usage

# 飞牛的 manifest 版本号必须是 X.Y.Z 形式，预发布后缀会被拒绝
FPK_VERSION="$(printf '%s' "${VERSION}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ -z "${FPK_VERSION}" ]; then
    echo "无法从 ${VERSION} 解析出 X.Y.Z 版本号，飞牛套件要求该格式" >&2
    exit 1
fi
if [ "${FPK_VERSION}" != "${VERSION}" ]; then
    echo "==> 飞牛要求 X.Y.Z 版本号，${VERSION} 将记录为 ${FPK_VERSION}"
fi

if [ "${SKIP_IMAGE_CHECK}" != "1" ]; then
    echo "==> 校验镜像 ${IMAGE}:${IMAGE_TAG} 是否已推送"
    if ! docker manifest inspect "${IMAGE}:${IMAGE_TAG}" > /dev/null 2>&1; then
        echo "镜像 ${IMAGE}:${IMAGE_TAG} 不存在。" >&2
        echo "飞牛不会在设备上构建镜像，compose 引用的标签必须已经推送到镜像仓库。" >&2
        echo "请先完成 Docker 镜像推送，或设置 SKIP_IMAGE_CHECK=1 跳过该检查。" >&2
        exit 1
    fi
fi

OUT_DIR="$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

APP_DIR="${WORK_DIR}/${APP_NAME}"
cp -a "${TEMPLATE_DIR}/." "${APP_DIR}/"

echo "==> 渲染 manifest 与 docker-compose.yaml"
# fnOS 的 manifest 是纯 INI 风格键值对，官方生成的模板里没有注释，
# 因此这里把模板注释过滤掉，只把数据写进产物。
sed -e "s/@VERSION@/${FPK_VERSION}/g" \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' \
    "${APP_DIR}/manifest" > "${WORK_DIR}/manifest.new"
mv "${WORK_DIR}/manifest.new" "${APP_DIR}/manifest"
sed -e "s|@IMAGE_TAG@|${IMAGE_TAG}|g" "${APP_DIR}/app/docker/docker-compose.yaml" > "${WORK_DIR}/compose.new"
mv "${WORK_DIR}/compose.new" "${APP_DIR}/app/docker/docker-compose.yaml"

if grep -q '@' "${APP_DIR}/manifest" "${APP_DIR}/app/docker/docker-compose.yaml"; then
    echo "模板中仍残留未渲染的占位符：" >&2
    grep -n '@' "${APP_DIR}/manifest" "${APP_DIR}/app/docker/docker-compose.yaml" >&2
    exit 1
fi

echo "==> 获取 fnpack ${FNPACK_VERSION}"
FNPACK="${WORK_DIR}/fnpack"
FNPACK_URL="https://static2.fnnas.com/fnpack/fnpack-${FNPACK_VERSION}-linux-amd64"
if ! curl -fsSL --retry 3 --retry-all-errors -o "${FNPACK}" "${FNPACK_URL}"; then
    echo "下载 ${FNPACK_URL} 失败，请检查网络或调整 FNPACK_VERSION。" >&2
    exit 1
fi
chmod 0755 "${FNPACK}"

echo "==> 执行 fnpack build"
( cd "${APP_DIR}" && "${FNPACK}" build )

BUILT="${APP_DIR}/${APP_NAME}.fpk"
[ -f "${BUILT}" ] || { echo "fnpack 未产出 ${BUILT}" >&2; exit 1; }

echo "==> 校验产物结构"
MAGIC="$(head -c 2 "${BUILT}" | od -An -tx1 | tr -d ' \n')"
case "${MAGIC}" in
    1f8b) echo "    容器格式: gzip"; SHOULD_LIST="tar" ;;
    504b) echo "    容器格式: zip"; SHOULD_LIST="zip" ;;
    *) echo "    容器格式: 未知 (magic ${MAGIC})，跳过内容清点"; SHOULD_LIST="" ;;
esac

if [ "${SHOULD_LIST}" = "tar" ]; then
    if ! tar -tzf "${BUILT}" | grep -qx 'manifest'; then
        echo "fpk 内容中缺少 manifest" >&2
        tar -tzf "${BUILT}" >&2
        exit 1
    fi
    echo "    内容清点通过"
elif [ "${SHOULD_LIST}" = "zip" ]; then
    if ! unzip -l "${BUILT}" | grep -q 'manifest'; then
        echo "fpk 内容中缺少 manifest" >&2
        exit 1
    fi
    echo "    内容清点通过"
fi

FPK_NAME="${APP_NAME}-${FPK_VERSION}.fpk"
install -m 0644 "${BUILT}" "${OUT_DIR}/${FPK_NAME}"

FPK_SIZE="$(du -m "${OUT_DIR}/${FPK_NAME}" | cut -f1)"
echo "==> 完成：${OUT_DIR}/${FPK_NAME} (${FPK_SIZE} MiB, 镜像 ${IMAGE}:${IMAGE_TAG})"
