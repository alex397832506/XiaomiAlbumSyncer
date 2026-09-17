# packaging

把 Xiaomi Album Syncer 打包成飞牛 fnOS、群晖 DSM 7、威联通 QTS 三个平台的套件。

面向使用者的安装说明在仓库根目录的 [README](../README.md#nas-套件飞牛--群晖--威联通)，本文只讲打包本身的实现与约定。

## 目录结构

```
packaging/
├── common/
│   ├── bin/xas-launch.sh        群晖与威联通共用的应用启动脚本
│   └── exiftool-wrapper.sh      内置 ExifTool 的入口，随包装为 exiftool/bin/exiftool
├── fnos/                        飞牛 fpk 项目模板
│   ├── manifest                 应用元信息
│   ├── config/privilege         运行身份
│   ├── config/resource          Docker 项目与数据共享目录声明
│   ├── cmd/                     应用生命周期脚本
│   ├── app/docker/              compose 模板
│   └── wizard/                  安装向导（当前为空，但目录必须存在）
├── synology/                    群晖 SPK 模板
│   ├── INFO                     套件元信息，字段顺序对齐官方 pkg_dump_info
│   ├── conf/privilege           运行身份声明
│   ├── scripts/                 生命周期脚本
│   └── ui/config                桌面入口配置
└── qnap/                        威联通 QPKG 模板
    ├── header.sh.in             自解压安装头
    ├── qpkg.cfg                 套件元信息
    ├── package_routines         安装/卸载钩子
    └── shared/                  随包投放的服务脚本
```

构建脚本位于 [`.github/scripts/nas/`](../.github/scripts/nas)，工作流是
[`.github/workflows/nas-packages.yml`](../.github/workflows/nas-packages.yml)。

## 三平台实现要点

### 飞牛 fnOS

使用官方 `fnpack` 工具打包，项目结构由 `fnpack create --template docker --without-ui true`
生成的模板而来，因此产物天然符合飞牛的校验规则。

两个硬约束：

- 飞牛**不会在设备上构建镜像**，套件只是个容器编排描述，引用的镜像标签必须已经推送到仓库。
  标签不一致会在用户安装时表现为 `manifest unknown` / `EOF`，因此构建脚本会用
  `docker manifest inspect` 提前拦下。
- 第三方应用目前**只支持 x86_64**，`manifest` 里的 `platform` 固定为 `x86`。
- `manifest` 的 `version` 必须是 `X.Y.Z`，预发布后缀会被裁剪（`0.18.0-rc.1` 记录为 `0.18.0`）。

### 群晖 DSM 7

SPK 就是一个未压缩 tar，成员顺序为：

```
INFO  LICENSE  PACKAGE_ICON.PNG  PACKAGE_ICON_256.PNG  conf  package.tgz  scripts  [ui]
```

`INFO` 必须排在第一位，`package.tgz` 使用 xz 压缩——这两点都对齐官方
`pkgscripts-ng` 里的 `pkg_make_spk` / `pkg_make_package`，构建脚本显式列出成员顺序，
不依赖 `ls` 的排序行为。构建结束还会再校验一次首个成员确实是 `INFO`。

几个容易踩的点：

- `os_min_ver` 不得低于 `7.0-40000`，构建脚本会断言。
- **未签名套件拿不到 root**（需要 Synology 开发者令牌），因此 `conf/privilege` 固定
  `run-as: package`，应用监听 8080 这个非特权端口。
- `arch` 只能用 DSM 7 的架构族取值：`x86_64` 与 `armv8`，对应关系见官方 `plat_to_family()`。
  `armv7`（alpine / alpine4k）没有对应二进制，暂不支持。
- 桌面入口依赖 `dsmuidir` + `dsmappname`，后者使用第三方命名空间
  `com.coooolfan.packages.xiaomi-album-syncer`。若某个 DSM 版本拒装，可用
  `DSM_UI=0` 重新构建，此时会去掉 `ui/`、`dsmuidir` 与 `dsmappname`，应用改用
  `http://<NAS>:8080` 直接访问。

### 威联通 QTS

QPKG 是自解压文件，自前向后为：

```
[自解压头] [control.tar] [data.tar.gz] [100 字节尾部]
```

- 头部负责定位安装卷、校验 CPU 架构、用 `dd` + `tar` 取出后面两段归档，最后执行 `qinstall.sh`，
  以 `exit 10` 结束（要求 QTS 删除 .qpkg 文件本身）。`script_len` 用等宽占位符回填，
  替换前后文件长度不变，避免自指的长度计算。
- `control.tar` 是未压缩 tar，内含一个 gzip 过的 `control.tar.gz`，存放
  `qpkg.cfg` / `package_routines` / `qinstall.sh` / `built_info`。
- `qinstall.sh` 直接从 QNAP 官方仓库 [qnap-dev/QDK](https://github.com/qnap-dev/QDK) 拉取，
  **不在本仓库内置**，避免把第三方的安装器复制进来。可以用 `QDK_QINSTALL_SHA256`
  固定校验值，用 `QDK_REF` 指定引用。
- 尾部 100 字节为 `MODEL(10) + RESERVED(50) + NAME(20) + VERSION(10) + "QNAPQPKG  "`，
  构建脚本会校验长度与标记。
- `QPKG_VER` 限长 10 字符。预发布版本会先去掉连字符（`0.18.0-rc.1` → `0.18.0rc.1`），
  仍然超长才截断。因此套件文件名里的版本号可能与 Release 版本号不同。
- 套件图标 `.qpkg_icon.gif` / `.qpkg_icon_80.gif` / `.qpkg_icon_gray.gif` 必须放在
  **data 包**的根目录，`qinstall.sh` 的 `copy_qpkg_icons` 是从安装目录读取它们的。

## 为什么群晖和威联通不用原生二进制

CI 在 `ubuntu-24.04`（glibc 2.39）上产出的 GraalVM 原生镜像要求 `GLIBC_2.34`：

```
$ python3 verify-glibc.py --max 2.26 <原生二进制>
最高需求: GLIBC_2.34
```

而群晖 DSM 7.0/7.1 的 glibc 只有 2.26，威联通 QTS 5.x 也普遍更低，设备上会直接
`version 'GLIBC_2.34' not found` 起不来。Eclipse Temurin 的运行时基线是 glibc 2.17，
可以覆盖全部目标机型，因此套件改用 JAR + jlink 裁剪出的运行时。

## 为什么套件要自带 Perl

ExifTool 是 Perl 程序，而且应用用到了 `-if` 条件表达式与 `-overwrite_original`，
无法用其它语言的替代实现顶替。但群晖 DSM 默认不带 Perl，威联通各机型差异也大。

因此套件随包分发一份 Perl 运行时，取自 **Debian 9（stretch）归档**：

- 该版本基于 glibc 2.24，实测其中所有 ELF 引用的最高符号版本只有 `GLIBC_2.17`，
  低于 DSM 7.0/7.1 的 2.26，留有余量。
- stretch 已进入归档，软件包内容不再变化，构建可复现。

## 本地构建

依赖：`bash`、`python3`、`curl`、`tar`、`xz`、`ImageMagick`、`docker`。

```bash
VERSION=0.18.0
ARCH=x86_64          # 或 arm64 / armv8 / arm_64，视平台而定

# 1) 内置 ExifTool（可选，省略则套件不含 EXIF 处理能力）
./.github/scripts/nas/build-exiftool-dist.sh --arch "${ARCH}" --out dist/exiftool

# 2) 共用的载荷，需要 JAVA_HOME 指向 JDK 以调用 jlink
JAVA_HOME=/path/to/jdk25 ./.github/scripts/nas/build-payload.sh \
    --arch "${ARCH}" --jar dist/app.jar --exiftool-dist dist/exiftool --out dist/payload

# 3) 各平台产物
./.github/scripts/nas/build-synology.sh --version "${VERSION}" --arch x86_64 \
    --payload dist/payload --out dist/spk
./.github/scripts/nas/build-qnap.sh --version "${VERSION}" --arch x86_64 \
    --payload dist/payload --out dist/qpkg
./.github/scripts/nas/build-fnos.sh --version "${VERSION}" \
    --image coolfan1024/xiaomi-album-syncer --image-tag "${VERSION}" --out dist/fpk
```

## 构建期自动校验

打包流程内建了若干断言，任何一条不通过都会让构建失败，而不是把坏包发出去：

- `verify-glibc.py`：遍历随包 ELF，断言所需的最高 glibc 符号版本不超过 2.26。
- `build-exiftool-dist.sh`：确认 `exiftool -ver` 有输出，并用一张最小 JPEG 走通 `-j -G`，
  覆盖真正的 Perl XS 模块加载路径。
- `build-payload.sh`：`java -version` 能跑，随后真正启动应用并等待端口响应，60 秒内没起来即失败。
- `build-synology.sh`：断言 `os_min_ver` 正确、SPK 首个成员是 `INFO`。
- `build-qnap.sh`：断言头部无残留占位符、`script_len` 替换后长度不变、产物总长
  等于「头部 + control + data + 100」、尾部标记为 `QNAPQPKG`。
- `build-fnos.sh`：断言镜像标签真实存在（`SKIP_IMAGE_CHECK=1` 可跳过）、模板占位符已全部渲染。

## 环境变量速查

| 变量 | 作用 | 默认值 |
| --- | --- | --- |
| `EXIFTOOL_VERSION` | 内置 ExifTool 版本 | `13.57` |
| `FNPACK_VERSION` | 飞牛打包工具版本 | `1.2.3` |
| `GLIBC_BASELINE` | 允许的最高 glibc 版本 | `2.26` |
| `DSM_UI` | 设为 `0` 时不生成群晖桌面入口 | `1` |
| `QDK_REF` | 拉取 `qinstall.sh` 的 git 引用 | `master` |
| `QDK_QINSTALL_SHA256` | 固定 `qinstall.sh` 的校验值 | 空 |
| `SKIP_IMAGE_CHECK` | 设为 `1` 跳过飞牛镜像存在性校验 | `0` |
