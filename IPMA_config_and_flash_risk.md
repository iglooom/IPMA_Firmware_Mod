# IPMA LKA/LCA thresholds — configuration route & flashing risk

## PART A — Configuration route: NOT FOUND (negative result)

### What the IPMA actually exposes
Local UCDS/FORScan exports (`/home/gl/Projects/ford/ab/Direct_IPMA_*.xml`,
`ucds share/Direct_IPMA_221024_.xml`, `*.uuw`) show the IPMA at 0x706 exposes
exactly these writable configuration DIDs:

| DID | Len | Content | As-Built equivalent |
|---|---|---|---|
| `DE00` | 8 B | feature-enable config block 1 | 706-01-01 / 706-01-02 |
| `DE01` | 12 B | feature-enable config block 2 (last 8 B always zero) | 706-02-0x |
| `DE02` | 15 B | feature-enable config block 3 (last 4 B ~always zero) | 706-03-0x |
| `DE03` | 12 B | all zero in every sample seen | 706-04-0x |
| `D700`/`D701` | 4 B | variant/HW descriptor (1 varying byte each) | — |
| `FD05`/`FD06`/`FD07` | 16–20 B | IEEE-754 floats = **camera alignment/calibration** (yaw/pitch/roll) | — |
| `F1xx` | — | read-only part numbers (F110/F111/F113/F120/F124/F188/F18C) | — |

Total writable config surface: **35 bytes** (DE00+DE01+DE02) plus alignment floats.

### The negative finding
Across 7 independent IPMA config samples (C346 MY11, C520 MY13 x3, C520 MY17 x2,
US Escape, EU Kuga) **no byte and no u16 in DE00–DE03 holds any value plausibly
representing a speed threshold** — nothing equal to 40, 50, 64, 65, 80, and no
u16be 400/500/640/800.

Every observed value is in {00,01,02,03,04,05,06,08,0B,11,13,21,22,2A,3F,6A,FF} —
the signature of **enumerated feature-enable flags**, not a scalar calibration.
Forum practice corroborates this: every documented Ford As-Built lane-keeping mod
(fordescape.org, mavericktruckclub, f150forum) *enables or disables* features;
no source anywhere describes tuning a threshold via As-Built.

**Conclusion: there is no configuration route to lower the LKA/LCA speed gates.**
The 40 mph / 65 km/h figure is a firmware constant, confirmed as a product
specification by Ford's own owner manual, not a configurable parameter.

### Where the threshold actually lives (high confidence)
`CV4T-14F398-AF` (**DATA**, "Application Parameters", 17 KB @ 0x00003000) contains
four identical 1032-byte (0x408) calibration records, each with the axis:

```
0 0 50 100 150 200 300 301 400 500 500 | 40 30 20
```

`0…500` = 0…50.0 mph in 0.1 mph. Ford's manual states LKA works above
**40 mph (64/65 km/h)** — exactly the 400 in this axis. Cross-version check:
BM5T-14F398-AG has 2 copies of the same pattern, F1FT-14F398-AG has 3.
The structure is stable across three firmware generations. This is a strong
locator but still not a proven use-site (no disassembly of the consumer code).

---

## PART B — Flashing risk

### Internal checksum: SOLVED (verified, not speculation)
Each image carries a `BootNfo` descriptor whose 12-char label is the
`UA.D.C._CRCst` string (actually `"A.D.C._CRCst"` at +0x10; the leading `U` is
the low byte of the preceding length word). Layout:

```
+0x00  "BootNfo\0"
+0x08  u32 length-ish word
+0x0C  u32 magic  = 0xAA5AA555
+0x10  char[12]   = "A.D.C._CRCst"     <- CRC struct marker
+0x1C  u32 start  = block load address
+0x20  u32 end    = last byte address
+0x24  u32 crc                          <- the stored checksum
```

**Algorithm (brute-forced and confirmed): standard CRC-32
(poly 0x04C11DB7, init 0xFFFFFFFF, reflected in/out, xorout 0xFFFFFFFF — i.e.
`zlib.crc32`) over the entire block image with the 4 CRC bytes at +0x24 removed
from the stream** (not zeroed — skipped).

Verified 10/10 across three independent firmware generations:

| Image | stored | computed |
|---|---|---|
| CV4T-14F397-AF (app) | 0xB8B8EC7A | match |
| CV4T-14F397-BF (DSP) | 0x18D4AC6D | match |
| CV4T-14F398-AF (param) | 0xCEDEF18D | match |
| CV4T-14F399-AF (SBL) | 0x31B60A17 | match |
| BM5T-14F397-AG/-BG, BM5T-14F398-AG | — | match |
| F1FT-14F397-AG/-BE, F1FT-14F399-AD | — | match |

`vbftool findsum` was never needed. Note the BRIEF's premise was wrong: the
parent dir `/home/gl/Projects/ford/IPMA/` holds **two more complete IPMA sets**
(F1FT-* rel 4.93.06, BM5T-* rel 4.5.5), which provided the cross-version proof.

A patch must therefore repair, in order:
1. BootNfo CRC-32 at block offset +0x24
2. VBF per-block CRC-16/CCITT-FALSE
3. VBF header `file_checksum` (CRC-32)

`vbftool patch` handles 2 and 3; step 1 is new and must be done first.
(No evidence of any *additional* CRC table or signature was found.)

### Recovery
Erase regions across all three generations:

| Part | Type | Erase region |
|---|---|---|
| 14F397-A* | EXE app | 0x00020000 (or 0x00010000) + ~0xDCB08 |
| 14F397-B* | EXE DSP | 0x00200000 + ~0x1724BC |
| 14F398-A* | DATA param | 0x00003000 + 0x4428 (CV4T/BM5T) |
| 14F399-A* | SBL | *no erase block* — RAM-loaded, call 0x820000 |

**Nothing ever erases below 0x00003000.** The primary bootloader and vector table
live in that untouched low region. The SBL (`CV4T-14F399-AF`) is not flashed at
all — it is downloaded into RAM at 0x820000 and executed to provide the flash
driver (it contains a `SuperFlash` routine table). So a failed application flash
leaves the primary bootloader intact; the module still answers at 0x706 in
programming session and can be re-flashed with the OEM VBF.

This is the standard Ford recoverable topology. Brick risk is low **provided the
primary bootloader region is never targeted** — which no OEM VBF does.

### Risk differential — the important point
The threshold candidate is in **CV4T-14F398-AF**, the DATA/parameter part:
17 KB, its own isolated 0x4428-byte erase region, does not touch application
code. A bad parameter flash is recoverable by re-flashing the same 17 KB part,
and its erase never intersects the 883 KB application. Patching *this* file is
materially lower-risk than patching the application.

### Verdict
- Configuration route: **does not exist** — high confidence, negative result.
- Firmware route: **moderate, managed risk**, not a brick risk, *if* the
  parameter part (14F398) is the target and the BootNfo CRC-32 is repaired.
- Unresolved: no disassembly-level proof that the 400/500 axis is the LKA/LCA
  gate, and no confirmation that the PSCM (CV6T-14C217) does not enforce its own
  independent speed gate. Both must be settled before any write.
