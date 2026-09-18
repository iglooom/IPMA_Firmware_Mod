# IPMA disassembly — shared briefing

## Objective

Prove, from code, that the LKA speed threshold lives at the addresses found by
static data analysis and confirmed on-vehicle:

```
mem 0x05458   17.94 f32be   LKA arm       (= 64.58 km/h)
mem 0x05454   16.67 f32be   LKA suppress  (= 60.01 km/h)
mem 0x05DE4   64.6  f32be   arm, km/h mirror
mem 0x06AE0   64.6  f32be   arm, km/h mirror
```

A 20-minute instrumented drive measured the real thresholds as **64.72 km/h
arm** (n=17, median) and **59.53 km/h suppress** (n=11) — matching the stored
constants to +0.14 / −0.48 km/h, hysteresis included. So the *values* are
certain; what is missing is the **use-site**: the instruction that loads one of
these addresses and compares it against road speed.

Why it matters: the value is stored **three times** (one m/s pair, two km/h
mirrors). Before editing we must know which copy the firmware actually reads,
or a patch may change a copy nobody consults.

## Target images

```
bins/CV4T-14F397-AF_blk0_0x00020000.bin   903944 B  load 0x00020000  Application
bins/CV4T-14F397-BF_blk0_0x00200000.bin  1516732 B  load 0x00200000  DSP Application
bins/CV4T-14F398-AF_blk0_0x00003000.bin    17448 B  load 0x00003000  Parameters (DATA)
bins/CV4T-14F399-AF_blk0_0x00820000.bin     4912 B  load 0x00820000  Secondary Bootloader
```

**mem address = load address + file offset.** All under
`/home/gl/Projects/ford/IPMA/Research/`.

Two further OEM generations exist for cross-checking:
`/home/gl/Projects/ford/IPMA/` holds **F1FT-\*** (rel 4.93.06) and **BM5T-\***
(rel 4.5.5) complete sets.

## Architecture (established, >95 % confidence)

**Renesas M32R — MCU M32192 — big-endian**, Continental **CSF2xx** camera
platform. Evidence: literal strings `M32192` and `SuperFlash` in the SBL and
application; a big-endian ascending pointer table at SBL file `0x130C`
(`00 82 10 20`, `00 82 10 40`, …) landing inside the SBL's own
`0x820000..0x821330` span; source paths `../src/sys/csf2xx/sysswinit.c`.

The **DSP Application** (`14F397-BF`) is **not** directly-executable M32R —
compressed or encrypted. Do not waste time disassembling it.

**M32R has no FPU.** All float comparisons go through **soft-float helper
routines** (compiler runtime, e.g. `__lesf2`/`__cmpsf2`-style). Expect the
threshold compare to be a *call*, not a single instruction.

## No off-the-shelf tooling exists

Checked on this machine: Ghidra 11.x processors (`/opt/ghidra`) include V850,
SuperH, TriCore — **no M32R**. radare2/rasm2 has `v850` and `sh`, **no m32r**.
capstone is not installed and does not support M32R either.

**So a disassembler must be written**, exactly as was done successfully for the
PSCM's DSP56800E in `/home/gl/Projects/ford/PSCM/Research/work/disasm/`.
Read `flow56800e.py` there for the house pattern: recursive-descent from known
entry points, `--selftest` with hand-verified encodings, refusal to emit
speculative output.

Binutils *upstream* supports m32r (`m32r-elf-objdump`); it is not installed
here. If you can install a cross-binutils quickly (`uv`, distro package,
prebuilt toolchain), that is a legitimate shortcut and far better than a
hand-rolled decoder — **but you must then validate it** against the known
entry point before trusting a single line.

## M32R encoding essentials (VERIFY these against documentation)

State any correction you find; do not trust this section blindly.

* Instructions are **16-bit or 32-bit**, packed into 32-bit words. A word holds
  either one 32-bit instruction or two 16-bit instructions.
* The **two MSBs of a halfword** select the format; 16-bit instructions may be
  paired with a `||` (parallel) or sequential marker.
* 16 general registers `R0..R15`; **R14 = link register**, **R15 = stack
  pointer**.
* **`LD24 Rd, #imm24`** builds a 24-bit constant in one instruction — this is
  the primary way a 24-bit address like `0x005458` is materialised. **Searching
  for `LD24` with an immediate equal to a target address is the single highest-
  value pattern hunt**, and it can be done *before* a full disassembler exists.
* `SETH Rd, #imm16` + `OR3 Rd, Rd, #imm16` is the other address-building idiom
  (high half then low half) for full 32-bit constants.
* Loads are typically `LD Rd, @(disp,Rs)` — so a base register plus a small
  displacement is the common way to reach a struct field. A threshold at
  `0x5458` may be reached as `base=0x5000 + disp=0x458`, or as a record base
  plus a field offset — **do not assume the full address appears as a literal**.

## Calibration block structure (already proven)

Self-describing. Region index at file `0x008C` (load `0x308C`), 16-byte rows
`[load_addr, size, flags, tag]`, address-chained. Element-size table at file
`0x43A8` (load `0x73A8`), rows `[next, tag, total_size, chunk_size]`; every
total is an exact multiple of its chunk, so the file declares its own strides.

Relevant tables:

| tag | load addr | total | stride | records |
|---|---|---|---|---|
| `0x30A01038` | `0x04A84` | `0x1020` | `0x408` | 4 |
| `0x30A01058` | `0x05AA4` | `0x0680` | `0x1A0` | 4 |
| `0x30A01048` | `0x06578` | `0x0AD0` | `0x2B4` | 4 |
| `0x30A01068` | `0x06348` | `0x0230` | `0x008C` | 4 |

The threshold pair sits in table `0x30A01038`, **record 2**, fields `+0x1C0`
(suppress) and `+0x1C4` (arm). The km/h mirrors are field `+0x000` of tables
`0x30A01048` and `0x30A01058`, also record 2.

The drive confirmed **this vehicle runs variant record 2**. How the firmware
selects record 2 at runtime is unknown and is itself a valuable finding.

## Rules of engagement

* **Read-only.** Never modify any `.VBF` or `.bin`.
* Ground every claim in an address plus the command/output that produced it.
* **Never fabricate disassembly.** If the decoder is unvalidated, say so. A
  well-supported "I could not decode this" is a genuine result; invented
  instructions are worse than nothing because they would justify a flash.
* Validate any decoder against **known ground truth** before using it:
  - the SBL's VBF header declares `call 0x820000` — the entry point;
  - the SBL pointer table at file `0x130C` lists in-range function addresses;
  - branch targets must land on instruction boundaries;
  - functions should end in returns (`JMP R14` / equivalent).
* Work under `/home/gl/Projects/ford/IPMA/Research/work/`. A venv is fine for
  *your* tooling.
* stdlib python3 (`/usr/bin/python3` is 3.14); PEP 668 blocks system pip, use
  `uv` or a venv.
