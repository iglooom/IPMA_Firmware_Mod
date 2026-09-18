# M32R assembler and disassembler tools

A self-contained, reproducible wrapper around GNU Binutils 2.42 for **big-endian
M32R** firmware work.  It replaces the ad-hoc `work/tools` build and supplies:

- `bin/m32r-disasm` — disassemble a raw M32R binary at its load address;
- `bin/m32r-asm` — assemble M32R GAS source into a flat binary;
- `bin/m32r-verify-vectors.py` — validate an M32R `BRA` vector table;
- `build.sh` — build and install the required M32R GNU Binutils programs.

The vendored source archive is GNU Binutils 2.42, whose SHA-256 is checked before
building.  Build products are deliberately ignored; the checked-in toolset is
small and reproducible rather than a host-specific binary distribution.

## Requirements

Linux or another POSIX host with Bash, Python 3, a C/C++ compiler, `make`, `tar`,
`xz`, `sha256sum`, and standard binutils build dependencies.  The first build
uses local `vendor/binutils-2.42.tar.xz`; no network access is required.

## Install / build

From this directory:

```bash
./build.sh
```

This creates `toolchain/bin/` with `m32r-elf-as`, `m32r-elf-objdump`,
`m32r-elf-objcopy`, and the other Binutils programs.  To use more parallel jobs:

```bash
JOBS=8 ./build.sh
```

## Disassemble a raw firmware region

A raw binary has no embedded load address.  Always supply the mapped address:

```bash
./bin/m32r-disasm firmware.bin 0x20000 firmware.dis
```

This is equivalent to:

```bash
toolchain/bin/m32r-elf-objdump -D -b binary -m m32r -EB \
  --adjust-vma=0x20000 firmware.bin > firmware.dis
```

`-EB` is intentional: the target firmware is big-endian.  A wrong base makes
branch targets and literal addresses misleading.

## Assemble a flat binary

Write GNU assembler syntax, for example:

```asm
.text
.global start
start:
        nop
        bra start
```

Then assemble it:

```bash
./bin/m32r-asm patch.s patch.bin
```

The wrapper invokes `m32r-elf-as -EB` and uses `objcopy -O binary`, so the output
is raw bytes rather than an ELF file.  Use the underlying assembler directly
when an ELF object, symbols, or relocations are required:

```bash
toolchain/bin/m32r-elf-as -EB -o patch.o patch.s
toolchain/bin/m32r-elf-objdump -dr patch.o
```

## Verify candidate vectors

M32R `BRA` is `0xFF` followed by a signed 24-bit word displacement.  A useful
positive control for a candidate image is that vector-table branches land inside
the image:

```bash
./bin/m32r-verify-vectors.py firmware.bin 0x20000
```

It scans the first `0x90` bytes by default.  Increase that range if needed:

```bash
./bin/m32r-verify-vectors.py firmware.bin 0x20000 --bytes 0x200
```

A non-zero exit status means no BRA was found or at least one discovered BRA
lands outside the image.

## Test

After building, run:

```bash
./tests/smoke-test.sh
```

The test assembles a tiny program, verifies its exact bytes
(`70 00 f0 00 ff 00 00 00`), and confirms that the wrapper disassembles it as
`nop || nop` followed by a branch to its own bundle.

## Reading output and limitations

- `->` in objdump output is sequential 16-bit pairing; `||` is parallel VLIW
  execution.  In the smoke test, two `nop` slots occupy one 32-bit bundle.
- GNU Binutils 2.42 handles M32R, M32RX, and M32R2 integer/DSP instructions, but
  does **not** decode M32R FPU instructions.  FPU words appear as `*unknown*`;
  do not mistake those for invalid code.
- `objdump -D` decodes every byte, including data.  Treat apparent instructions
  in tables and float pools as data until control flow or references support
  them.

## License

The wrapper scripts and documentation in this directory are project material.
The vendored GNU Binutils source is distributed under its upstream licensing;
see its `COPYING` file after extraction in `.build/binutils-2.42/`.
