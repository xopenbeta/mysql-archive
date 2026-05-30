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

echo "Building placeholder package for arch=$ARCH mysql=$MYSQL_VERSION series=$SERIES"

# Download source tarball (best-effort, don't fail if unavailable)
SRC_URL="https://cdn.mysql.com/Downloads/MySQL-${SERIES}/mysql-${MYSQL_VERSION}.tar.gz"
SRC_ARCHIVE="mysql-${MYSQL_VERSION}.tar.gz"
if command -v curl >/dev/null 2>&1; then
  echo "Attempting to download source from $SRC_URL"
  curl -fSL "$SRC_URL" -o "$SRC_ARCHIVE" || echo "Download failed or not present; continuing with placeholder"
fi

# Create a minimal package layout to upload as artifact. This avoids long compile times in CI
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/mysql-${MYSQL_VERSION}"
echo "Placeholder MySQL build for $ARCH $MYSQL_VERSION" > "$TMPDIR/mysql-${MYSQL_VERSION}/README.txt"
if [ -f "$SRC_ARCHIVE" ]; then
  mkdir -p "$TMPDIR/mysql-${MYSQL_VERSION}/src"
  tar -xzf "$SRC_ARCHIVE" -C "$TMPDIR/mysql-${MYSQL_VERSION}/src" || true
fi

# Example: include a tiny bin stub
mkdir -p "$TMPDIR/mysql-${MYSQL_VERSION}/bin"
cat > "$TMPDIR/mysql-${MYSQL_VERSION}/bin/mysqld" <<'EOF'
#!/bin/sh
echo "This is a placeholder mysqld binary for testing CI artifacts."
EOF
chmod +x "$TMPDIR/mysql-${MYSQL_VERSION}/bin/mysqld"

# Pack the tarball
tar -C "$TMPDIR" -czf "$TARBALL_PATH" "mysql-${MYSQL_VERSION}"

# Generate SHA256
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$TARBALL_PATH" | awk '{print $1 "  " $2}' > "$SHA_PATH"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$TARBALL_PATH" | awk '{print $1 "  " $2}' > "$SHA_PATH"
else
  # fallback using openssl
  openssl dgst -sha256 -binary "$TARBALL_PATH" | openssl enc -base64 -A | awk '{print $0 "  '"$TARBALL_NAME"'"}' > "$SHA_PATH" || true
fi

echo "Created artifact: $TARBALL_PATH"
echo "Created checksum: $SHA_PATH"

# Clean up
rm -rf "$TMPDIR"

echo "Done"
