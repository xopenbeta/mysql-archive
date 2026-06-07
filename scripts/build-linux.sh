#!/usr/bin/env bash
set -euo pipefail

ARCH="$1"
MYSQL_VERSION="$2"
# 从版本号自动推导系列号，例如 8.0.41 → 8.0，8.4.4 → 8.4
SERIES="${MYSQL_VERSION%.*}"

WORKDIR="$(pwd)"
OUTDIR="$WORKDIR/dist-artifacts"
mkdir -p "$OUTDIR"

TARBALL_NAME="mysql-${MYSQL_VERSION}-linux-${ARCH}.tar.gz"
TARBALL_PATH="$OUTDIR/$TARBALL_NAME"
SHA_PATH="$TARBALL_PATH.sha256"
INSTALL_DIR="${WORKDIR}/mysql-${MYSQL_VERSION}"
BUILD_DIR="${WORKDIR}/mysql-build"
SRC_DIR="${WORKDIR}/mysql-src"

echo "=== Building MySQL ${MYSQL_VERSION} for linux/${ARCH} ==="

# ── 安装构建依赖 ────────────────────────────────────────────────────
sudo apt-get update -y
sudo apt-get install -y \
  cmake ninja-build gcc g++ make \
  libssl-dev libncurses-dev libcurl4-openssl-dev \
  pkg-config bison \
  libtirpc-dev rpcsvc-proto \
  libaio-dev libldap-dev libsasl2-dev \
  libnuma-dev

# ── 下载源码 ────────────────────────────────────────────────────────
SRC_URL="https://cdn.mysql.com/Downloads/MySQL-${SERIES}/mysql-${MYSQL_VERSION}.tar.gz"
SRC_ARCHIVE="${WORKDIR}/mysql-${MYSQL_VERSION}.tar.gz"
echo "Downloading source from ${SRC_URL}"
curl -fSL "${SRC_URL}" -o "${SRC_ARCHIVE}"

mkdir -p "${SRC_DIR}"
tar -xzf "${SRC_ARCHIVE}" -C "${SRC_DIR}" --strip-components=1

# ── CMake 配置 ──────────────────────────────────────────────────────
mkdir -p "${BUILD_DIR}"

CMAKE_EXTRA_ARGS=()
if [[ "${SERIES}" == "8.0" || "${SERIES}" == "5.7" ]]; then
  # MySQL 8.0/5.7 需要外部 Boost，通过 CMake 自动下载
  CMAKE_EXTRA_ARGS+=(
    "-DDOWNLOAD_BOOST=1"
    "-DWITH_BOOST=${WORKDIR}/boost"
  )
fi

if [[ "${SERIES}" == "5.7" ]]; then
  CMAKE_EXTRA_ARGS+=("-DCMAKE_POLICY_VERSION_MINIMUM=3.5")
fi

DEFAULT_COLLATION="utf8mb4_0900_ai_ci"
if [[ "${SERIES}" == "5.7" ]]; then
  DEFAULT_COLLATION="utf8mb4_general_ci"
fi

cmake -B "${BUILD_DIR}" -S "${SRC_DIR}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DWITH_SSL=system \
  -DWITH_UNIT_TESTS=OFF \
  -DENABLED_LOCAL_INFILE=1 \
  -DDEFAULT_CHARSET=utf8mb4 \
  -DDEFAULT_COLLATION="${DEFAULT_COLLATION}" \
  -DWITH_JEMALLOC=OFF \
  -DWITH_NUMA=1 \
  "${CMAKE_EXTRA_ARGS[@]}"

# ── 编译并安装 ──────────────────────────────────────────────────────
cmake --build "${BUILD_DIR}" --parallel "$(nproc)"
cmake --install "${BUILD_DIR}"

# ── Strip 精简体积 ───────────────────────────────────────────────────
find "${INSTALL_DIR}/bin" -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
find "${INSTALL_DIR}/lib" -name "*.so*" -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true

# ── 打包 ────────────────────────────────────────────────────────────
tar -C "${WORKDIR}" -czf "${TARBALL_PATH}" "mysql-${MYSQL_VERSION}"

# ── 生成 SHA256 ──────────────────────────────────────────────────────
sha256sum "${TARBALL_PATH}" | awk '{print $1 "  " $2}' > "${SHA_PATH}"

echo "Created artifact: ${TARBALL_PATH}"
echo "Created checksum: ${SHA_PATH}"
echo "Done"
