#!/usr/bin/env bash
# Verify the wrappers by assembling and disassembling a known M32R program.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m32r-tools-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

"$ROOT/bin/m32r-asm" "$ROOT/tests/smoke.s" "$tmp/smoke.bin"
actual=$(od -An -tx1 -v "$tmp/smoke.bin" | tr -d ' \n')
expected=7000f000ff000000
[[ "$actual" == "$expected" ]] || {
    printf 'Unexpected assembled bytes: %s\n' "$actual" >&2
    exit 1
}

"$ROOT/bin/m32r-disasm" "$tmp/smoke.bin" 0x20000 "$tmp/smoke.dis"
grep -q 'nop || nop' "$tmp/smoke.dis"
grep -q 'bra.*0x20004' "$tmp/smoke.dis"
printf 'M32R assemble/disassemble smoke test passed.\n'
