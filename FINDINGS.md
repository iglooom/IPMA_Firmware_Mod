# IPMA speed gates — consolidated findings

Read-only research. No VBF has been modified.

## Toolchain (the former blocker, now solved)

GNU binutils 2.42 `objdump` built for `--target=m32r-elf`, used from the build
tree at `work/build/binutils/objdump` (no install, no sudo):

```bash
objdump -D -b binary -m m32r -EB --adjust-vma=<load> image.bin
```

**Validated** on the SBL: 1228 words, only 9 `*unknown*` (0.73 %); 223/225
branch targets land in-range, 4-byte aligned, on decoded instruction
boundaries; every pointer-table entry is a clean prologue ending in `jmp lr`.

## THE GATE ENCODING — `[arm @ +0x000, band @ +0x010]`, km/h

Both features use the same layout, and both reproduce the drive measurements:

| table | rec | arm | band | drop = arm − band | measured on the drive |
|---|---|---|---|---|---|
| `0x30A01048` / `0x30A01058` | **2** | **64.60** | **5.00** | **59.60** | LKA **64.56 / 59.44** |
| `0x30A01068` | all | **80.00** | **5.00** | **75.00** | LCA **80.01 / 75.03** |

LKA deltas −0.04 / −0.16 km/h. **LCA deltas +0.01 / +0.03 km/h** — inside the
CAN signal's own noise.

Two independent features, two different tables, one shared encoding, both
matching measurement. **This is what closes the LCA question**, which single-
value scanning never could: the drop-out is not stored anywhere, it is
*computed* as `arm − band`, which is why no 75 km/h literal exists.

Live addresses (this vehicle runs **variant record 2**):

```
LKA arm   mem 0x06AE0 (tag48 rec2 +0x000) = 64.6    and mirror 0x05DE4 (tag58)
LKA band  mem 0x06AF0 (tag48 rec2 +0x010) =  5.0    and mirror 0x05DF4
LCA arm   mem 0x06348 (tag68 rec0 +0x000) = 80.0    (invariant, all 4 records)
LCA band  mem 0x06358 (tag68 rec0 +0x010) =  5.0
```

## Access mechanism — proven from code

Calibration is resolved **by 32-bit tag, never by address**:

```
ba41c:  d4 c0 30 a0   seth r4,#0x30a0
ba420:  84 e4 10 38   or3  r4,r4,#0x1038     <- tag 0x30A01038
ba428:  fe ff fc bf   bl   0xb9724           <- resolver, returns a pointer
```

All tags (`…1038/1048/1058/1068/1078/1088/1098`) are built this way and passed
to the resolver at `0x0B9724`; `0x05BEE8` range-checks tags against
`0x30A01099`. Callers then index the returned pointer with
`ld rX,@(disp,rBase)`.

**This explains the earlier clean negative** — zero LD24 or SETH+OR3 references
to any calibration address exist, because addresses are never literals.
(My `find_ld24.py` result was correct, not a failure.)

## A hysteresis gate located in code — verbatim

```
c13fc:  a0 c8 01 c0   ld r0,@(448,r8)      <- +0x1C0
c1400:  d2 00 02 00   *unknown*            <- FPU compare
c1404:  60 02 f0 00   ldi r0,#2
c1408:  a1 c8 01 4c   ld r1,@(332,r8)      <- state
c140c:  b1 10 00 03   bne r1,r0,0xc1418
c1410:  a0 c8 01 c4   ld r0,@(452,r8)      <- +0x1C4
c1414:  d2 00 02 40   *unknown*            <- same FPU op, different condition
```

Textbook two-threshold hysteresis: a state variable selects which threshold to
compare against. The two FPU words differ by one nibble — same operation, two
conditions.

**ISA CORRECTION — my brief was wrong.** I told the subagents *"M32R has no
FPU, expect a soft-float call."* False: this ECU's M32R **has hardware FP**.
~302 words with byte0 in `0xD0..0xDF` are FPU instructions binutils cannot
decode under `-m m32r`, `m32rx` or `m32r2`. The comparison is inline, not a
helper call. That wrong premise would have sent the search down a dead end.

## The remaining ambiguity — stated plainly

The located code reads offsets `+0x1C0`/`+0x1C4`, which in table `0x30A01038`
are the **m/s** pair (16.67 / 17.94). But its base register comes from
`ld24 r8,0x82dc6c` — **RAM**, not flash. So either:

* the RAM struct is a copy of tag38 record 2 → the m/s pair is operative; or
* the RAM struct has its own layout and `+0x1C0` means something else there.

Evidence favours the **km/h** `[arm, band]` pair:

* the drop-out fits: measured leave `59.3 … 59.8`, km/h gives **59.60**
  (inside the range), m/s gives **60.01** (above every sample);
* the arm cannot discriminate — 64.60 vs 64.584 are effectively identical;
* **LCA decides it**: the same `[arm, band]` encoding on tag68 predicts
  80.00/75.00 against measured 80.01/75.03, and the m/s table has no LCA
  counterpart that works.

Not resolved: the RAM base provenance (`r8` from `@(80,sp)`) was not traced
back to the resolver.

## Cross-version corroboration (three OEM generations)

* **CV4T 4.27.0** — 4 records; rec2 = 16.670/17.940 m/s.
* **BM5T 4.5.5** — identical index, tags and strides; **2 records only**, and
  **no 16.67/17.94 pair anywhere**. CV4T rec0/rec1 vs BM5T rec0/rec1 are
  **byte-identical over 0x408 bytes**. Consistent with a lower-spec Transit
  lacking the high-threshold variant.
* **F1FT 4.93.06** — container physically restructured (load `0x902000`, no tag
  table, stride `0x3F8`), yet the quadruple `[16.670, 17.940, 68.0, 70.0]`
  survives intact as a standalone 16-byte row **at the same index 2**.

A coincidence would not survive a container rewrite. The record set is
per-vehicle-variant; **what selects the record at runtime is still unknown** —
nothing in the calibration encodes a selector, so it must be application-side
(likely a configuration DID).

## BootNfo internal checksum

`zlib.crc32` over the block with the 4 bytes at `+0x24` **skipped**:

```
CV4T-14F398-AF   stored 0xCEDEF18D  calc 0xCEDEF18D   MATCH   (verified by me)
CV4T-14F399-AF   stored 0x31B60A17  calc 0x31B60A17   MATCH   (verified by me)
BM5T-14F398-AG   stored 0x2F9A9B6A  calc 0x2F9A9B6A   MATCH
F1FT-14F398-AG   descriptor differs (no 'A.D.C._CRCst', 0xC shorter)  NOT SOLVED
```

**Do not attempt to patch the F1FT part** — its checksum is unreproduced.
The CV4T part is fully repairable.

## Status

| question | state |
|---|---|
| Which module gates? | **ANSWERED** — IPMA. PSCM allows from 39 km/h. |
| LKA threshold location | **CONFIRMED** behaviourally, two candidate encodings |
| LCA threshold location | **STRONG** — 80.0/5.0 predicts 80.01/75.03 |
| Access mechanism | **PROVEN** — tag resolver + displacement |
| Exact operative copy | **OPEN** — km/h favoured, RAM base untraced |
| Runtime record selector | **OPEN** |
| Patch repair procedure | **KNOWN** — BootNfo CRC-32 → block CRC-16 → file CRC-32 |
