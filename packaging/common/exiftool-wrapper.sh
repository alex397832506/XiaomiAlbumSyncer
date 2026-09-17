#!/bin/sh
# 套件内置 ExifTool 入口。
#
# 用随包的 Perl 运行时解释官方 exiftool 脚本，因此既不依赖 NAS 上是否安装 Perl，
# 也不受 NAS glibc 版本影响（Perl 运行时基于 glibc 2.24 构建，可覆盖 DSM 7.0+ 与 QTS 5.x）。
#
# 该脚本在打包时被安装为 <载荷>/exiftool/bin/exiftool，并由 xas-launch.sh
# 放进 PATH 最前面，于是应用默认配置里的 exifToolPath="exiftool" 会命中这里。
set -u

case "$0" in
    /*) XAS_ET_SELF="$0" ;;
    *) XAS_ET_SELF="$(pwd)/$0" ;;
esac
XAS_ET_BIN="${XAS_ET_SELF%/*}"
XAS_ET_ROOT="${XAS_ET_BIN%/*}"
ET_RT="${XAS_ET_ROOT}/perl-runtime"

PERL_BIN="${ET_RT}/usr/bin/perl"
if [ ! -x "${PERL_BIN}" ]; then
    echo "ExifTool: bundled Perl runtime not found at ${PERL_BIN}" >&2
    exit 1
fi

# libperl 等共享库随包分发，需要显式告知动态链接器
ET_LD=""
for d in "${ET_RT}"/usr/lib/*/ "${ET_RT}"/usr/lib; do
    [ -d "$d" ] && ET_LD="${ET_LD:+${ET_LD}:}${d}"
done
LD_LIBRARY_PATH="${ET_LD}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export LD_LIBRARY_PATH

# Perl 的模块搜索路径在编译期被写死为绝对路径，这里按随包目录结构重新拼装
ET_INC=""
for d in "${ET_RT}"/usr/lib/*/perl/5.* \
         "${ET_RT}"/usr/lib/*/perl-base \
         "${ET_RT}"/usr/share/perl/5.* \
         "${ET_RT}"/usr/share/perl5 \
         "${XAS_ET_ROOT}/lib"; do
    [ -d "$d" ] && ET_INC="${ET_INC} -I${d}"
done

# shellcheck disable=SC2086
exec "${PERL_BIN}" ${ET_INC} "${XAS_ET_ROOT}/libexec/exiftool-impl" "$@"
