#!/usr/bin/env bash
set -euo pipefail

ARCH="$1"
MYSQL_VERSION="$2"
# 从版本号自动推导系列号，例如 8.0.41 → 8.0，8.4.4 → 8.4
SERIES="${MYSQL_VERSION%.*}"

WORKDIR="$(pwd)"
OUTDIR="$WORKDIR/dist-artifacts"
mkdir -p "$OUTDIR"

TARBALL_NAME="mysql-${MYSQL_VERSION}-macos-${ARCH}.tar.gz"
TARBALL_PATH="$OUTDIR/$TARBALL_NAME"
SHA_PATH="$TARBALL_PATH.sha256"
INSTALL_DIR="${WORKDIR}/mysql-${MYSQL_VERSION}"
BUILD_DIR="${WORKDIR}/mysql-build"
SRC_DIR="${WORKDIR}/mysql-src"

echo "=== Building MySQL ${MYSQL_VERSION} for macOS/${ARCH} ==="

# ── 安装构建工具 ────────────────────────────────────────────────────
brew install cmake ninja pkg-config bison
export PATH="$(brew --prefix bison)/bin:$PATH"

# ── 处理 OpenSSL：区分原生 arm64 和交叉编译 x86_64 ─────────────────
HOST_ARCH="$(uname -m)"   # 运行时真实架构（runner 为 arm64）

if [[ "${ARCH}" == "x86_64" && "${HOST_ARCH}" == "arm64" ]]; then
  # 交叉编译：需要 x86_64 版本的 OpenSSL
  OPENSSL_SRC_DIR="${WORKDIR}/openssl-src"
  OPENSSL_INSTALL_DIR="${WORKDIR}/openssl-x86_64"
  OPENSSL_VERSION="3.3.2"

  echo "Building x86_64 OpenSSL ${OPENSSL_VERSION} from source..."
  curl -fSL "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
    | tar -xz -C "${WORKDIR}" \
    && mv "${WORKDIR}/openssl-${OPENSSL_VERSION}" "${OPENSSL_SRC_DIR}"

  pushd "${OPENSSL_SRC_DIR}"
  ./Configure darwin64-x86_64 \
    --prefix="${OPENSSL_INSTALL_DIR}" \
    no-shared no-tests
  make -j"$(sysctl -n hw.logicalcpu)"
  make install_sw
  popd

  OPENSSL_ROOT_DIR="${OPENSSL_INSTALL_DIR}"
  CMAKE_OSX_ARCH="x86_64"
else
  # 原生编译
  brew install openssl@3
  OPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
  CMAKE_OSX_ARCH="${ARCH}"
fi

# ── 下载 MySQL 源码 ─────────────────────────────────────────────────
SRC_URL="https://cdn.mysql.com/Downloads/MySQL-${SERIES}/mysql-${MYSQL_VERSION}.tar.gz"
SRC_ARCHIVE="${WORKDIR}/mysql-${MYSQL_VERSION}.tar.gz"
echo "Downloading source from ${SRC_URL}"
curl -fSL "${SRC_URL}" -o "${SRC_ARCHIVE}"

mkdir -p "${SRC_DIR}"
tar -xzf "${SRC_ARCHIVE}" -C "${SRC_DIR}" --strip-components=1

# ── CMake 配置 ──────────────────────────────────────────────────────
mkdir -p "${BUILD_DIR}"

CMAKE_EXTRA_ARGS=()
if [[ "${SERIES}" == "8.0" ]]; then
  CMAKE_EXTRA_ARGS+=(
    "-DDOWNLOAD_BOOST=1"
    "-DWITH_BOOST=${WORKDIR}/boost"
  )
fi

cmake -B "${BUILD_DIR}" -S "${SRC_DIR}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DCMAKE_OSX_ARCHITECTURES="${CMAKE_OSX_ARCH}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
  -DOPENSSL_ROOT_DIR="${OPENSSL_ROOT_DIR}" \
  -DWITH_SSL=system \
  -DWITH_UNIT_TESTS=OFF \
  -DENABLED_LOCAL_INFILE=1 \
  -DDEFAULT_CHARSET=utf8mb4 \
  -DDEFAULT_COLLATION=utf8mb4_0900_ai_ci \
  -DWITH_JEMALLOC=OFF \
  "${CMAKE_EXTRA_ARGS[@]}"

# ── 编译并安装 ──────────────────────────────────────────────────────
cmake --build "${BUILD_DIR}" --parallel "$(sysctl -n hw.logicalcpu)"
cmake --install "${BUILD_DIR}"

# ── Strip 精简体积 ───────────────────────────────────────────────────
find "${INSTALL_DIR}/bin" -type f -exec strip {} \; 2>/dev/null || true

# ── 打包 ────────────────────────────────────────────────────────────
tar -C "${WORKDIR}" -czf "${TARBALL_PATH}" "mysql-${MYSQL_VERSION}"

# ── 生成 SHA256 ──────────────────────────────────────────────────────
shasum -a 256 "${TARBALL_PATH}" | awk '{print $1 "  " $2}' > "${SHA_PATH}"

echo "Created artifact: ${TARBALL_PATH}"
echo "Created checksum: ${SHA_PATH}"
echo "Done"
