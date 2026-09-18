#!/usr/bin/env python3
"""Validate M32R big-endian branch vectors in a raw image."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


def bra_target(address: int, word: int) -> int | None:
    """Return an M32R BRA target, or None when *word* is not a BRA."""
    if word >> 24 != 0xFF:
        return None
    displacement = word & 0x00FFFFFF
    if displacement & 0x00800000:
        displacement -= 0x01000000
    return ((address & ~3) + displacement * 4) & 0xFFFFFFFF


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check in-range M32R BRA entries in a raw big-endian vector table."
    )
    parser.add_argument("image", type=Path)
    parser.add_argument("base", type=lambda value: int(value, 0), help="load address, e.g. 0x20000")
    parser.add_argument("--bytes", type=lambda value: int(value, 0), default=0x90,
                        help="number of bytes to scan from the start (default: 0x90)")
    args = parser.parse_args()

    try:
        image = args.image.read_bytes()
    except OSError as exc:
        parser.error(f"cannot read {args.image}: {exc}")
    if len(image) < 4:
        parser.error("image must contain at least one 32-bit word")

    scan_end = min(args.bytes, len(image)) & ~3
    image_end = args.base + len(image)
    branches = 0
    in_range = 0

    for offset in range(0, scan_end, 4):
        word, = struct.unpack_from(">I", image, offset)
        address = args.base + offset
        target = bra_target(address, word)
        if target is None:
            continue
        branches += 1
        valid = args.base <= target < image_end
        in_range += valid
        print(f"{address:08x}: {word:08x}  BRA -> {target:08x} "
              f"{'IN-RANGE' if valid else 'OUT-OF-RANGE'}")

    print(f"BRA entries in range: {in_range}/{branches} (scanned {scan_end:#x} bytes)")
    return 0 if branches and in_range == branches else 1


if __name__ == "__main__":
    raise SystemExit(main())
