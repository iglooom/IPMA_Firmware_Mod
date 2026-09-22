# IPMA module — hardware, firmware set, memory map

Ford IPMA (Image Processing Module A) — the forward-facing camera that drives
Lane Keeping Aid, Lane Centering Aid, Lane Departure Warning, Traffic Sign
Recognition and Auto High Beam.

Vehicle under study: Ford C520 EU MY17, VIN `WF0AXXWPMAEL32600`.

---

## 1. Processor — Renesas M32R (M32192)

**Confidence: >95 %.** Five independent lines of evidence:

1. **Literal strings.** The SBL contains `M32192` at SBL block offset `0x4C`
   and `SuperFlash`; both also appear in the application image. M32192 is a
   Renesas/Mitsubishi M32R-family automotive MCU; *SuperFlash* is the
   SST/Mitsubishi flash-driver name used on those parts. (The calibration part
   does **not** carry these strings — it tags itself `CSF265`.)
2. **Platform tag.** `CSF2*` in the SBL and `CSF265` in the calibration part at
   block offset `0x28`, plus source paths `../src/sys/csf2xx/sysswinit.c` — the
   Continental **CSF2xx** camera platform, which is M32R-based.
3. **Endianness.** The SBL's pointer table at file `0x130C` holds
   `00 82 10 20`, `00 82 10 40`, `00 82 10 60`, … = big-endian `0x00821020`,
   `0x00821040`, … all inside the SBL's own `0x820000..0x821330` span, strictly
   ascending. Read little-endian they are `0x20108200` — far outside the image.
4. **Disassembly quality.** Decoded with `objdump -m m32r -EB`: 1228 words in
   the SBL, only 9 `*unknown*` (0.73 %); 223 of 225 branch targets land
   in-range, 4-byte aligned, on decoded instruction boundaries.
5. **Structure.** Every pointer-table entry is a clean prologue
   (`push r8 -> mv r8,r4`) terminating in `jmp lr`.

### The M32R HAS hardware floating point

**This corrects an early assumption.** An initial brief stated *"M32R has no
FPU, expect soft-float helper calls"* — **false**, and it would have sent the
search for the threshold comparison down a dead end.

~302 instruction words in verified code regions have byte0 in `0xD0..0xDF`
with byte1 high-nibble 0 (e.g. `d0 01 01 d0`, `d2 00 02 00`). **binutils cannot
decode these** under `-m m32r`, `-m m32rx` or `-m m32r2` — they render as
`*unknown*`. They cluster densely in the most-called leaf routines
(`0x02FBBC`, `0x02FC04`, `0x02FD2C`) which manipulate `0x3f80` / `0xbf80` /
`0x8000` / `0x5f80` — float sign and exponent constants.

Consequence: **float comparisons are inline FPU instructions, not calls.**

### Instruction encodings used in this work

Derived from validated objdump output, not from guesswork:

```
LD24 Rd,#imm24    word = 0xE0000000 | (Rd << 24) | imm24
                  byte0 = 0xE0|Rd, bytes 1..3 = immediate, big-endian
                  always 32-bit, therefore always 4-byte aligned
SETH Rd,#hi16     mask 0xF0FF0000  base 0xD0C00000
OR3  Rd,Rs,#lo16  mask 0xF0F00000  base 0x80E00000
```

`LD24` is the single-instruction way to materialise a 24-bit address.
`SETH`+`OR3` builds a full 32-bit constant.

---

## 2. The firmware set

Four VBF parts, all `ecu_address = 0x706`, all container-verified clean
(block CRC-16 + file CRC-32 + 0 trailing bytes):

| Part | Type | Load | Size | Erase region | Description |
|---|---|---|---|---|---|
| `CV4T-14F397-AF` | EXE | `0x00020000` | 883 KB | `0x00020000` len `0xDCB08` | Release 4.27.0 **Application** |
| `CV4T-14F397-BF` | EXE | `0x00200000` | 1.45 MB | `0x00200000` len `0x1724BC` | Release 4.27.0 **DSP Application** |
| `CV4T-14F398-AF` | DATA | `0x00003000` | 17 KB | `0x00003000` len `0x4428` | Release 4.27.0 **Application Parameters** |
| `CV4T-14F399-AF` | SBL | `0x00820000` | 4.9 KB | *(none)* | **Secondary Bootloader**, `call 0x820000` |

`CV4T-14F397-BF` (the "DSP Application") is **not directly-executable M32R** —
it is compressed or encrypted. Do not attempt to disassemble it.

Two further complete OEM generations exist locally for cross-checking:

```
/home/gl/Projects/ford/IPMA/F1FT-14F39*.VBF                       release 4.93.06
/home/gl/Projects/ford/IPMA/Software IPMA Transit to FF3/BM5T-*   release 4.5.5
```

### Memory layout

```
0x00000000 .. 0x00002FFF   primary bootloader  (NEVER erased by any OEM VBF)
0x00003000 .. 0x00007427   calibration / Application Parameters
0x00020000 .. 0x000FCB07   application code
0x00200000 .. 0x003724BB   DSP application
0x00820000 .. 0x0082132F   SBL, RAM-loaded at flash time
0x0082DC6C                 RAM: working copy of calibration records (observed)
```

**Nothing in any OEM VBF erases below `0x3000`.** The primary bootloader and
reset vectors are never targeted by a field-flashable part — this is what makes
a failed flash recoverable.

---

## 3. BootNfo integrity descriptor

Every independently-flashable block carries its own integrity descriptor at
block offset 0, so the bootloader can validate a region before jumping into it:

| Offset | Size | Content |
|---|---|---|
| `+0x00` | 8 | `"BootNfo\0"` |
| `+0x08` | 4 | length word |
| `+0x0C` | 4 | magic `0xAA5AA555` |
| `+0x10` | 12 | `"A.D.C._CRCst"` |
| `+0x1C` | 4 | start address |
| `+0x20` | 4 | end address (inclusive — i.e. `len − 1`) |
| `+0x24` | 4 | **stored CRC-32** |
| `+0x28` | 8 | platform tag — `"CSF265"` in the calibration part, `"CSF2*"` in the SBL |
| `+0x30` | 12 | build tag, e.g. `"_FSPR0000"` |
| `+0x53` | 12 | part number, e.g. `"CV4T14F398AF"` |

The **`M32192` MCU string and `GENERAL00001` live in the SBL only**, at SBL
block offsets `0x4C` and `0x30`. They are *not* present in the calibration
part — that block carries `CSF265` and its own part number instead.

**Algorithm:** `zlib.crc32` over the whole block **with the 4 CRC bytes at
`+0x24` skipped** (removed from the stream — *not* zeroed).

Verified:

```
CV4T-14F398-AF  start 0x00003000 end 0x00007427  stored 0xCEDEF18D  MATCH
CV4T-14F399-AF  start 0x00820000 end 0x0082132F  stored 0x31B60A17  MATCH
BM5T-14F398-AG  start 0x00003000 end 0x00006C17  stored 0x2F9A9B6A  MATCH
F1FT-14F398-AG  different two-tier scheme — per-region ~crc32 SOLVED (see below)
```

`A.D.C.` = Advanced Driver-assistance Camera (the supplier's module family);
`_CRCst` = "CRC structure". The string `UA.D.C._CRCst` that `strings` reports
is an artefact — the leading `U` is byte `0x55`, the low byte of the
`0xAA5AA555` magic immediately before the label.

**F1FT exception.** The F1FT descriptor has no `A.D.C._CRCst` label and is
0xC bytes shorter: start at `+0x10`, end at `+0x14`, top word at `+0x18`. It
also drops the CV4T whole-block CRC in favour of a **flat 28-row index at block
`0x8C`** whose per-region hash is the operative integrity layer:

```
region_hash = ~zlib.crc32(region) & 0xFFFFFFFF   (CRC-32 without the final XOR)
```

Verified reproducing 28/28 stored hashes and confirmed against the app CRC core
`0x0A8B50` and runtime validator `0x15D94`. The `+0x18` top word
(`0x340BC6D9`) is still not reproduced by any standard CRC but is not read at
runtime and covers only untouched metadata, so the F1FT part **is** patchable —
see `F1FT_speed_gates.md`. (This supersedes the earlier "do not patch F1FT".)

---

## 4. Toolchain

No distro package provides M32R support (Ghidra 11 has V850/SuperH/TriCore but
not M32R; radare2 and capstone likewise). Build binutils from source:

```bash
curl -O https://ftp.gnu.org/gnu/binutils/binutils-2.42.tar.xz
tar xf binutils-2.42.tar.xz && mkdir build && cd build
../binutils-2.42/configure --target=m32r-elf --disable-nls \
    --disable-werror --disable-gdb --disable-sim
make -j$(nproc) all-binutils all-opcodes
```

~4 minutes; no install and no root needed. Use from the build tree:

```bash
work/build/binutils/objdump -D -b binary -m m32r -EB \
    --adjust-vma=0x00020000 bins/CV4T-14F397-AF_blk0_0x00020000.bin
```

**Validate before trusting output.** The SBL is the ground-truth specimen: its
VBF header declares `call 0x820000`, the pointer table at file `0x130C` lists
in-range function entries, and every one begins with a `push` and ends in
`jmp lr`.

Note the SBL's first `0x5C` bytes are the plaintext BootNfo descriptor, not
code — disassembling from `0x820000` yields ASCII decoded as instructions.
Real code begins at **`0x82005C`**.

### Separating code from data

Statistical, and necessary: `*unknown*` density per 2 KB page. Verified code
regions run **0–8 %**; data pools run **~38 %**. In the application image
82.8 % of bytes are code across 35 spans. Three apparent `ld24 r8,0x3000` hits
turned out to be coincidental bytes inside 37.9 %-unknown data pools — the
density filter is what rejected them.
