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
BREW_PACKAGES=(ninja pkg-config bison)
if [[ "${SERIES}" == "5.7" ]]; then
  BREW_PACKAGES+=(curl)
else
  BREW_PACKAGES+=(cmake)
fi

brew install "${BREW_PACKAGES[@]}"
export PATH="$(brew --prefix bison)/bin:$PATH"

CMAKE_BIN="cmake"
CURL_ROOT_DIR=""
if [[ "${SERIES}" == "5.7" ]]; then
  CMAKE_VENV_DIR="${WORKDIR}/.cmake-venv"
  python3 -m venv "${CMAKE_VENV_DIR}"
  "${CMAKE_VENV_DIR}/bin/python" -m pip install --upgrade pip
  "${CMAKE_VENV_DIR}/bin/python" -m pip install "cmake<4"
  CMAKE_BIN="${CMAKE_VENV_DIR}/bin/cmake"
  CURL_ROOT_DIR="$(brew --prefix curl)"
fi

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
  # Apple Silicon runner 上交叉构建 x86_64 OpenSSL 时，汇编路径不稳定；
  # 禁用 asm 以换取可重复构建。
  MACOSX_DEPLOYMENT_TARGET="12.0" ./Configure darwin64-x86_64 \
    --prefix="${OPENSSL_INSTALL_DIR}" \
    no-asm no-shared no-tests
  MACOSX_DEPLOYMENT_TARGET="12.0" make -j"$(sysctl -n hw.logicalcpu)"
  make install_sw
  popd

  OPENSSL_ROOT_DIR="${OPENSSL_INSTALL_DIR}"
  CMAKE_OSX_ARCH="x86_64"
  # 交叉编译时 CMake 无法正确处理 zstd 内置的 x86_64 汇编文件，
  # 禁用汇编优化以避免链接时出现 Undefined symbols for architecture x86_64。
  CROSS_COMPILE_FLAGS="-DZSTD_DISABLE_ASM"
  # Xcode 15+ 新链接器在交叉编译 x86_64 时存在 "imageOffset32 fixup" Bug，
  # 回退到旧链接器以规避该问题。
  CROSS_LINKER_FLAGS="-Wl,-ld_classic"
else
  # 原生编译
  brew install openssl@3
  OPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
  CMAKE_OSX_ARCH="${ARCH}"
  CROSS_COMPILE_FLAGS=""
  CROSS_LINKER_FLAGS=""
fi

# ── 下载 MySQL 源码 ─────────────────────────────────────────────────
SRC_URL="https://cdn.mysql.com/Downloads/MySQL-${SERIES}/mysql-${MYSQL_VERSION}.tar.gz"
SRC_ARCHIVE="${WORKDIR}/mysql-${MYSQL_VERSION}.tar.gz"
echo "Downloading source from ${SRC_URL}"
curl -fSL "${SRC_URL}" -o "${SRC_ARCHIVE}"

mkdir -p "${SRC_DIR}"
tar -xzf "${SRC_ARCHIVE}" -C "${SRC_DIR}" --strip-components=1

if [[ "${SERIES}" == "9.6" ]]; then
  COLLATIONS_INTERNAL_CC="${SRC_DIR}/strings/collations_internal.cc"
  PARSE_OPTIONS_H="${SRC_DIR}/libs/mysql/strconv/decode/parse_options.h"

  if [[ ! -f "${PARSE_OPTIONS_H}" ]]; then
    echo "MySQL 9.6 compatibility patch target not found: ${PARSE_OPTIONS_H}" >&2
    exit 1
  fi

  if ! grep -Fq 'return Compound_parse_options<std::tuple<Format_t>>(format);' "${PARSE_OPTIONS_H}"; then
    echo "MySQL 9.6 compatibility patch did not find Format_t constructor return in ${PARSE_OPTIONS_H}" >&2
    exit 1
  fi

  if ! grep -Fq 'return Compound_parse_options<std::tuple<Repeat_t>>(repeat);' "${PARSE_OPTIONS_H}"; then
    echo "MySQL 9.6 compatibility patch did not find Repeat_t constructor return in ${PARSE_OPTIONS_H}" >&2
    exit 1
  fi

  if ! grep -Fq 'return Compound_parse_options<std::tuple<Checker_t>>(checker);' "${PARSE_OPTIONS_H}"; then
    echo "MySQL 9.6 compatibility patch did not find Checker_t constructor return in ${PARSE_OPTIONS_H}" >&2
    exit 1
  fi

  perl -0pi -e 's/return Compound_parse_options<std::tuple<Format_t>>\(format\);/return Compound_parse_options<std::tuple<Format_t>>{std::tuple<Format_t>{format}};/' "${PARSE_OPTIONS_H}"
  perl -0pi -e 's/return Compound_parse_options<std::tuple<Repeat_t>>\(repeat\);/return Compound_parse_options<std::tuple<Repeat_t>>{std::tuple<Repeat_t>{repeat}};/' "${PARSE_OPTIONS_H}"
  perl -0pi -e 's/return Compound_parse_options<std::tuple<Checker_t>>\(checker\);/return Compound_parse_options<std::tuple<Checker_t>>{std::tuple<Checker_t>{checker}};/' "${PARSE_OPTIONS_H}"

  if ! grep -Fq 'return Compound_parse_options<std::tuple<Format_t>>{std::tuple<Format_t>{format}};' "${PARSE_OPTIONS_H}"; then
    echo "MySQL 9.6 compatibility patch verification failed for Format_t constructor return in ${PARSE_OPTIONS_H}" >&2
    exit 1
  fi

  if ! grep -Fq 'return Compound_parse_options<std::tuple<Repeat_t>>{std::tuple<Repeat_t>{repeat}};' "${PARSE_OPTIONS_H}"; then
    echo "MySQL 9.6 compatibility patch verification failed for Repeat_t constructor return in ${PARSE_OPTIONS_H}" >&2
    exit 1
  fi

  if ! grep -Fq 'return Compound_parse_options<std::tuple<Checker_t>>{std::tuple<Checker_t>{checker}};' "${PARSE_OPTIONS_H}"; then
    echo "MySQL 9.6 compatibility patch verification failed for Checker_t constructor return in ${PARSE_OPTIONS_H}" >&2
    exit 1
  fi

  echo "Patched parse_options.h for macOS MySQL 9.6 aggregate construction compatibility"

  if [[ ! -f "${COLLATIONS_INTERNAL_CC}" ]]; then
    echo "MySQL 9.6 compatibility patch target not found: ${COLLATIONS_INTERNAL_CC}" >&2
    exit 1
  fi

  if ! grep -Fq 'CHARSET_INFO *find_in_hash(const sv_hash_map &hash, std::string_view key)' "${COLLATIONS_INTERNAL_CC}"; then
    echo "MySQL 9.6 compatibility patch did not find sv_hash_map find_in_hash() in ${COLLATIONS_INTERNAL_CC}" >&2
    exit 1
  fi

  if ! grep -Fq 'auto it = hash.find((key));' "${COLLATIONS_INTERNAL_CC}"; then
    echo "MySQL 9.6 compatibility patch did not find expected sv_hash_map lookup in ${COLLATIONS_INTERNAL_CC}" >&2
    exit 1
  fi

  perl -0pi -e 's/CHARSET_INFO \*find_in_hash\(const sv_hash_map &hash, std::string_view key\) \{\n  auto it = hash\.find\(\(key\)\);/CHARSET_INFO *find_in_hash(const sv_hash_map \&hash, std::string_view key) {\n  auto it = hash.find(std::string(key));/s' "${COLLATIONS_INTERNAL_CC}"

  if ! grep -Fq 'CHARSET_INFO *find_in_hash(const id_hash_map &hash, unsigned key)' "${COLLATIONS_INTERNAL_CC}"; then
    echo "MySQL 9.6 compatibility patch did not find id_hash_map find_in_hash() in ${COLLATIONS_INTERNAL_CC}" >&2
    exit 1
  fi

  if ! grep -Fq 'auto it = hash.find(key);' "${COLLATIONS_INTERNAL_CC}"; then
    echo "MySQL 9.6 compatibility patch verification failed for id_hash_map lookup in ${COLLATIONS_INTERNAL_CC}" >&2
    exit 1
  fi

  if ! grep -Fq 'CHARSET_INFO *find_cs_in_hash(const sv_hash_map &hash, std::string_view key)' "${COLLATIONS_INTERNAL_CC}"; then
    echo "MySQL 9.6 compatibility patch did not find sv_hash_map find_cs_in_hash() in ${COLLATIONS_INTERNAL_CC}" >&2
    exit 1
  fi

  perl -0pi -e 's/CHARSET_INFO \*find_cs_in_hash\(const sv_hash_map &hash, std::string_view key\) \{\n  auto it = hash\.find\(key\);/CHARSET_INFO *find_cs_in_hash(const sv_hash_map \&hash, std::string_view key) {\n  auto it = hash.find(std::string(key));/s' "${COLLATIONS_INTERNAL_CC}"

  if ! grep -Fq 'CHARSET_INFO *find_cs_in_hash(const sv_hash_map &hash, std::string_view key)' "${COLLATIONS_INTERNAL_CC}" || ! grep -Fq 'auto it = hash.find(std::string(key));' "${COLLATIONS_INTERNAL_CC}"; then
    echo "MySQL 9.6 compatibility patch verification failed for sv_hash_map find_cs_in_hash() in ${COLLATIONS_INTERNAL_CC}" >&2
    exit 1
  fi

  echo "Patched collations_internal.cc for macOS MySQL 9.6 string_view lookup compatibility"
fi

# ── CMake 配置 ──────────────────────────────────────────────────────
mkdir -p "${BUILD_DIR}"

CMAKE_EXTRA_ARGS=()
if [[ "${SERIES}" == "8.0" || "${SERIES}" == "5.7" ]]; then
  CMAKE_EXTRA_ARGS+=(
    "-DDOWNLOAD_BOOST=1"
    "-DWITH_BOOST=${WORKDIR}/boost"
  )
fi

if [[ "${SERIES}" == "5.7" ]]; then
  CMAKE_EXTRA_ARGS+=(
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DWITH_CURL=${CURL_ROOT_DIR}"
  )
fi

DEFAULT_COLLATION="utf8mb4_0900_ai_ci"
if [[ "${SERIES}" == "5.7" ]]; then
  DEFAULT_COLLATION="utf8mb4_general_ci"
fi

"${CMAKE_BIN}" -B "${BUILD_DIR}" -S "${SRC_DIR}" \
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
  -DDEFAULT_COLLATION="${DEFAULT_COLLATION}" \
  -DWITH_JEMALLOC=OFF \
  ${CROSS_COMPILE_FLAGS:+-DCMAKE_C_FLAGS="${CROSS_COMPILE_FLAGS}" -DCMAKE_CXX_FLAGS="${CROSS_COMPILE_FLAGS}"} \
  ${CROSS_LINKER_FLAGS:+-DCMAKE_SHARED_LINKER_FLAGS="${CROSS_LINKER_FLAGS}" -DCMAKE_EXE_LINKER_FLAGS="${CROSS_LINKER_FLAGS}"} \
  ${CMAKE_EXTRA_ARGS[@]+"${CMAKE_EXTRA_ARGS[@]}"}

# ── 编译并安装 ──────────────────────────────────────────────────────
"${CMAKE_BIN}" --build "${BUILD_DIR}" --parallel "$(sysctl -n hw.logicalcpu)"
"${CMAKE_BIN}" --install "${BUILD_DIR}"

# ── Strip 精简体积 ───────────────────────────────────────────────────
find "${INSTALL_DIR}/bin" -type f -exec strip {} \; 2>/dev/null || true

# ── 打包 ────────────────────────────────────────────────────────────
tar -C "${WORKDIR}" -czf "${TARBALL_PATH}" "mysql-${MYSQL_VERSION}"

# ── 生成 SHA256 ──────────────────────────────────────────────────────
shasum -a 256 "${TARBALL_PATH}" | awk '{print $1 "  " $2}' > "${SHA_PATH}"

echo "Created artifact: ${TARBALL_PATH}"
echo "Created checksum: ${SHA_PATH}"
echo "Done"
