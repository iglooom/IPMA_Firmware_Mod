#!/usr/bin/env bash
# Build a minimal GNU Binutils M32R assembler/disassembler toolchain.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VERSION=2.42
ARCHIVE="$ROOT/vendor/binutils-${VERSION}.tar.xz"
EXPECTED_SHA256=f6e4d41fd5fc778b06b7891457b3620da5ecea1006c6a4a41ae998109f85a800
SOURCE="$ROOT/.build/binutils-${VERSION}"
BUILD="$ROOT/.build/build"
PREFIX="$ROOT/toolchain"
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)}

if [[ ! -f "$ARCHIVE" ]]; then
    printf 'Missing vendored source archive: %s\n' "$ARCHIVE" >&2
    exit 1
fi

actual_sha256=$(sha256sum "$ARCHIVE" | awk '{print $1}')
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
    printf 'SHA-256 mismatch for %s\nexpected: %s\nactual:   %s\n' \
        "$ARCHIVE" "$EXPECTED_SHA256" "$actual_sha256" >&2
    exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
    mkdir -p "$ROOT/.build"
    tar -xf "$ARCHIVE" -C "$ROOT/.build"
fi

mkdir -p "$BUILD"
cd "$BUILD"
"$SOURCE/configure" \
    --target=m32r-elf \
    --prefix="$PREFIX" \
    --disable-nls \
    --disable-werror \
    --disable-gdb \
    --disable-sim \
    --disable-libdecnumber \
    --disable-readline
make -j"$JOBS" all-binutils all-gas
make install-binutils install-gas

printf 'Installed M32R tools in %s/bin\n' "$PREFIX"
