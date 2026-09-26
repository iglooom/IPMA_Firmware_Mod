# CV4T-14F397-BF — the DSP Application, opened

**Status: the "compressed or encrypted, do not disassemble" verdict in
`IPMA_module.md` §2 and `DISASM_BRIEF.md` is WRONG and is retracted here.**
The block is a **zlib stream in a 32-byte proprietary container**. It
decompresses cleanly, the plaintext is TI C6000 code, and every header field
has been reproduced arithmetically on **three** OEM generations.

Everything below was derived from the binaries; each claim names the offset and
check that produced it. Re-derive with `work/dsp/unwrap_dsp.py --selftest`.

---

## 1. The outer block

```
python3 $T info CV4T-14F397-BF.VBF
  sw_part_type  EXE      ecu_address 0x706      vbf 2.3
  blk0  load=0x00200000  len=0x001724BC
  blk1  load=0x00900048  len=0x10   "CV4T-14F397-BF\0B"
  blk2  load=0x00901EB0  len=0x10   (identical to blk1)
```

`blk1`/`blk2` are just the part-number stamp written twice into the
`0x90xxxx` config area — the same two addresses in *every* generation
(BM5T, CV4T, F1FT), which is why they were the one positive cross-version
datum in `F1FT_vs_CV4T_compatibility.md`.

The 1.45 MB `blk0` ends with the usual **BootNfo** descriptor at
`+0x17243C`, and this one is **big-endian** (the M32R host writes it), unlike
the inner container below:

| field | value |
|---|---|
| start | `0x00200000` |
| end | `0x003724BB` = load + len − 1 ✔ |
| stored CRC-32 | `0x18D4AC6D` |
| platform tag | `CSF265`, part `CV4T14F397BF` |

`zlib.crc32(block with the 4 CRC bytes at +0x24 removed)` = `0x18D4AC6D` —
**matches**, same recipe as every other IPMA part.

---

## 2. The inner container — solved

Bytes `0x00..0x1F` of the block are a header that the old analysis read as
random noise. It is **little-endian** (the DSP consumes it):

| off | size | field | CV4T |
|---|---|---|---|
| `0x00` | 4 | magic `19 C1 C0 AD` | identical in all 3 generations |
| `0x04` | 4 | compressed length | `0x172399` |
| `0x08` | 4 | uncompressed length | `0x21E098` |
| `0x0C` | 4 | **CRC-32 of the compressed payload** | `0xC0987970` |
| `0x10` | 4 | **CRC-32 of the decompressed image** | `0xA4CA6300` |
| `0x14` | 12 | zero | |
| `0x20` | … | **zlib stream** | starts `38 8D` |

Payload at `0x20` is standard zlib: `CM=8`, **`CINFO=3` → 2 KB window**
(a small-window build, which is why it is 12 % larger than default zlib and
why entropy sat at 7.99 and hid the structure).

All four computed fields match on all three OEM DSP parts:

| part | clen | ulen | got | crc32(payload) | crc32(plain) |
|---|---|---|---|---|---|
| CV4T-14F397-BF | `0x172399` | `0x21E098` | `0x21E098` ✔ | `0xC0987970` ✔ | `0xA4CA6300` ✔ |
| BM5T-14F397-BG | `0x1723B0` | `0x21E078` | `0x21E078` ✔ | `0x10F2F944` ✔ | `0x1A242256` ✔ |
| F1FT-14F397-BE | `0x176F5C` | `0x224480` | `0x224480` ✔ | `0xA6A09E1D` ✔ | `0x27261A63` ✔ |

Twelve independent numbers reproduced. This is not a coincidence.

---

## 3. What is inside: a second processor

The decompressed 2,220,184-byte image is **not** M32R. It is
**TI TMS320DM6437 (C64x+ DSP core), little-endian** — the IPMA is a
**two-processor module**, and this block is the vision processor's entire
program.

Proof, in descending strength:

1. The literal string **`src\kernel\LDPreprocess_TMS320DM6437.cpp`** at
   `0x21CCFC`.
2. C6000 exception-handler strings at `0x21A3BD`: `IERR=0x%x`, `NRP=0x%x`,
   `EFR=0x%x`, `Fetch packet exception`, `Execute patcket exception` *(sic)*,
   `Loop buffer exception` — these register names are C6000-specific.
3. **Structural**: in the code regions, 83 % of 32-byte fetch packets end with
   `p`-bit = 0 (correct C6000 parallel-bit framing); in the data regions it is
   50 %, i.e. noise. Measured, not assumed.
4. A `tic6x-elf` objdump (built here, §7) decodes those regions into coherent
   `.M1/.S2/.D2T1` unit-qualified instructions; the data regions decode to
   garbage. Only the *contrast* is being claimed — see the honesty note in §7.

The host M32R application's own strings corroborate a DaVinci SoC:
`PLL 0 setup ( DSP @ ? MHz )`, `PLL 1 setup ( VPSS @ ? MHz / DDR2 @ ? MHz )`,
`DDR2 setup … w/ ?-bit bus`, `DspACTL`, `/CCDC`, `/VPBE`.

---

## 4. The interesting part: the lane-detection algorithm is named in the clear

This is the module that actually finds the lane. The C++ translation units and
pipeline stages are all present as strings.

**Source files** (`src\kernel\…`, MSVC-style backslashes — built on Windows):

```
LaneDetectionAlgo.cpp          LaneDetectionAlgoTLB.cpp
LaneDetectionAlgoInit.cpp      LaneDetectionAlgoBlockage.cpp
LaneDetectionAlgoFeatures.cpp  LaneDetectionInput.cpp
LaneDetectionOutput.cpp        LaneDetectionParam.cpp
LDLaneTracker.cpp              LDBoundaryTracker.cpp
LDObstacleTracker.cpp          LDDashedSegmentTracker.cpp
LDYawRateEstimator.cpp         LDUDUtKalman.cpp   LDUDUtMatrix.cpp
LDLaneSensor.cpp               LDLaneSensorFlow.cpp
LDSpeedSensor.cpp              LDPreprocess.cpp   LDHistogram.cpp
clothoidtracker.cpp            FDLAlgo.cpp        Lane.cpp
```

**The pipeline, in order** (profiling-label table at `0x21A6E9`):

```
PixelPerMeter → InitPreprocess → Preprocess → Threshold → Canny → Extract
→ Group → TrackLB → TrackObstacles → MarkerTypeDetermination
→ MarkerConfidence → FindLaneBounds → LaneTracker → TrackMarkerHeights
→ YawRateEstimation → Ambiguous Situations → ConfidenceCalculation
→ AutoCalibrate → Blockage → NewLBTracks → ApplyTrackedPitch → FDLAlgo
→ UpdateLane → Finish
```

So: Canny edges → feature extraction → grouping → **clothoid** lane model with a
**UD-factorised Kalman filter** (`LDUDUtKalman`), plus obstacle and
dashed-segment trackers, marker-type classification, blockage detection and
online auto-calibration. `LDSpeedSensor.cpp` is notable given the speed-gate
work — the DSP has its own notion of vehicle speed.

**`LDSpeedSensor` matters for the threshold research**: the speed gate we
patched lives in the M32R calibration, but this file proves the DSP *also*
consumes speed. Whether it applies an independent minimum is **untested** and
is the obvious next question.

There is also a **traffic-sign recognition** stack (`SR*`/`SRCS`/`SRCL`/`SRFS`
prefixes): PCA + classifier chains (`SRCLApplyPcClassifier`, `pca transform
failed`, `unequal number of classes in inner and outer classifiers`,
`could not load classifier set`), Hough-style circle accumulators
(`SRCSAccumulateBar`, `maximum number of circles reached`,
`SRCSHcIslandPointsFrom4AccusFull`).

## 4a. Cross-version: BM5T 4.5.5 / CV4T 4.27.0 / F1FT 4.90.03

All three DSP parts unwrap with the same tool and **all three run the same
silicon**: `TMS320DM6437` appears exactly once in each plaintext.

```
python3 work/dsp/unwrap_dsp.py --selftest   ->  30/30 checks passed
```

| part | VBF description | plaintext | platform tag | build date |
|---|---|---|---|---|
| BM5T-14F397-BG | IPMA Release **4.5.5** DSP Application | 2,220,152 | `CSF265` | 2011-10-24 |
| CV4T-14F397-BF | IPMA Release **4.27.0** DSP Application | 2,220,184 | `CSF265` | 2012-10-08 |
| F1FT-14F397-BE | IPMA Version **4.90.03** : DSP Aplication *(sic)* | 2,245,760 | **`CSF2F0`** | 2014-10-09 |

### The plaintext has its own header — and it decodes

Bytes `0x00..0x160` of every decompressed image are a descriptor block, and
three fields there are now readable:

* **`+0x120` and `+0x134`: the version triple**, little-endian bytes:
  `04 1b 00` → 4.27.0, `04 05 05` → 4.5.5, `04 5a 03` → 4.90.03.
  Each **matches its VBF `description` string exactly** — three independent
  confirmations, so the decode is solid. This is a version stamp readable
  without any string parsing.
* **`+0x118`: a date**, `ff YY MM DD` → 2011-10-24 / 2012-10-08 / 2014-10-09,
  consistent with the release ordering.
* **`+0x100`: the platform tag**, `CSF265` vs `CSF2F0`.
* **`+0x151`**: `04 01 00`/`02 60 00` on both `CSF265` parts, `04 03 15`/`03 15 00`
  on F1FT — a second version-like pair, unidentified.

### The inner BootNfo is a PLACEHOLDER — this is the important one

The plaintext carries a BootNfo at `+0xDC`, but where the outer block has real
values, the inner one has **ASCII literals**:

```
inner  +0x1C..+0x28 = "AdstAdedCrcS"      <- Addr-start / Addr-end / CRC-Sum
outer  +0x1C..+0x28 = 00200000 003724bb 18d4ac6d   (real, verified)
```

Identical in all three generations. So the DSP image's own integrity slots are
**never filled in** — the container's zlib CRC-32 pair is the only integrity
over this block. That materially lowers the risk noted in §8, though the
`Checksum of CODE SEG %2x` string means a *runtime* self-check may still exist
elsewhere; this finding does not clear it.

### What actually changed

The software is the **same codebase, retuned and relocated** — not a rewrite:

* **All 25 `src\kernel\*.cpp` filenames are byte-identical across CV4T and F1FT.**
* String pools: 635 (CV4T) vs 636 (F1FT). The only meaningful new strings are
  `F1FT14F397BE`, `CSF2F0`/`csf2F0`; the only removed ones are the
  corresponding `CV4T14F397BF`, `CSF265`/`csf265`. Everything else is noise.
* The 24-stage pipeline list and the **245-entry country table are identical**
  (same set, same alpha-2/alpha-3, same `900 CE VCE` terminator).

Naive positional diffing reports ~0 % identity, which is misleading. Matching
32-byte runs at *any* offset:

| pair | runs ≥32 B | bytes matched | dominant offset delta |
|---|---|---|---|
| BM5T vs CV4T | 123 | 1,030,732 (46 %) | **`+0x48`** (95 of 123 runs) |
| F1FT vs CV4T | 218 | 973,244 (43 %) | `+0x5E48`/`+0x61C8` (86 of 218) |

Shingle containment (offset-insensitive, 24-byte windows): **BM5T↔CV4T 0.92**,
F1FT↔either **0.68**. So BM5T→CV4T is almost pure relocation by `0x48` bytes,
while F1FT is a genuine generational step that still shares two thirds of its
content. F1FT is **+25,576 bytes (`0x63E8`)** larger, and its match deltas
cluster near `0x6000` — i.e. roughly one block of new code was inserted early
and pushed everything after it down.

Landmark drift confirms the shift is global, not local:

```
                     LaneDetectionAlgo.cpp   country tbl   string pool
CV4T                      0x21A6CE            0x1025A8      0x217AEC
BM5T                      0x21A716 (+0x48)    0x1025F0      0x217B34 (+0x48)
F1FT                      0x220A76 (+0x63A8)  0x1083F0      0x21DCB4
```

### Correcting `F1FT_vs_CV4T_compatibility.md`

That document reports **"DSP image similarity to CV4T: Jaccard 0.004 / 0.000"**
and concludes the F1FT DSP is a *"different vision build for a different camera
board (0.000 content overlap), highest risk"*.

**The 0.000 is an artefact of comparing compressed streams.** Reproduced here:
compressed CV4T vs F1FT gives 0.0000 (7 shared 16-byte blocks); on the
**plaintexts** the same metric gives **0.507 Jaccard / 0.68 containment**.

The *conclusion* still stands, but on better evidence: F1FT is a `CSF2F0`
build and CV4T is `CSF265` — a **different camera board**, stated in the
firmware's own platform tag rather than inferred from a meaningless overlap
number. Do not mix them. Note also that the F1FT set is internally
**version-mismatched** (app 4.93.06, DSP 4.90.03, SBL 4.85.04), so "the F1FT
generation" is not one coherent version.

---

### The input signal list (`0x218140`) — the DSP's view of the vehicle

```
CAN whl spd L / R      CAN yaw rate        CAN head light
VDY velocity           VDY yaw rate (+offs, +qual)
VDY mot state (+conf)
IC state / act char / brightness / frame num / curr bin / exp time / ovr alg id
NAVI country           NAVI GPS lat        NAVI GPS lon
CALI cam pos X/Y/Z     CALI cam pitch/roll/yaw
CALI focal len         CALI pixel size     CALI prin ax X/Y
LR pitch angle         LR block det        LR cali odo/pitch/roll/yaw
VEH wheelbase          VEH steering variant   VEH speed unit
TSE struct version / traffic style / indicator
SUE struct version / speed unit
CCE struct version / country code
```

with fault suffixes ` not plausible`, ` signal not ok`, ` timeout`,
` not calibrated`. `VEH steering variant`, `VEH speed unit` and
`CCE country code` are configuration inputs — plausible members of the
**variant-selection** mechanism that `README.md` still lists as an open
question, though nothing here proves the *calibration record 2* selector.

### A 245-entry country table at `0x1025A8`

Full ISO-3166 set: name, numeric code, alpha-2, alpha-3, plus a per-country
pointer (191 non-NULL, into `0x80A21A20..0x80A24F48`) and a small index.
Strides are 0x20/0x28/0x38 — variable, name-length driven.

This is **region-dependent behaviour**, almost certainly the traffic-sign
ruleset (`TSE traffic style`, `SUE speed unit`) — i.e. the camera changes sign
interpretation and units by country, keyed off `NAVI country` / `CCE country
code`. `0x104BCE` ends with a non-ISO entry `900 CE VCE`, presumably a default.

### RTOS

Task names (`0x21B3A3`, `0x21BB7A`) are a classic TI DSP/BIOS set:
`TSK_ACTL_main`, `TSK_ccdc`, `TSK_MON`, `TSK_ERR`, `TSK_idle`,
`TSK_ROI_{HIGH,MID,LOW,BuildRoiList,DMAJobHandler}`, `TSK_MEAS_ASP`,
`TSK_UART_{TX,RX}`; devices `/CCDC`, `/VPBE`, `/MCASP`, `/UART0`;
`MSGQ`/`POOL`/`BUF`/`GIO` API error strings; `SYS abort called with message`.
A **UART** is wired up and there is a `TSK_MON` monitor task — a debug console
almost certainly exists on the board.

Vendor: `A.D.C. GmbH` (`0x21C58C`), platform `csf265`/`CSF265`.

---

## 5. The image is a debug-symbol-free release, but full of assert text

Strings such as `parameterassert failed.`, `autocode for srfs table
initialization out of date. recreate headers.`, `isl_overflow happened!!!Resize
SRCS_ISLAND_POINTS_MAX in srcs_islands.h`, `Videodriver initialization failed`,
`--> VSYNC-Counter asynchronous: old: %x new: %x`, and the German
`Video In Task Erstes Bild bekommen und zurueckgegeben` show a build with
diagnostics compiled in. Each one is a cross-reference handle: the code that
loads its address is the function that emits it.

---

## 6. Layout of the decompressed image

Classified by C6000 `p`-bit framing over 16 KB windows (`work/dsp/`):

```
0x000000..0x00C000   code (vectors + early init; H=6.1, p-bit 0.85)
0x00C000..0x0F8000   mixed code/data, high entropy (main algorithm mass)
0x0F7000..0x0F9000   constant-fill run (0x06 repeated)
0x0F8000..0x104000   data
0x104000..0x10C000   code
0x102400..0x105000   >>> country table (245 entries)
0x110000..0x134000   s32 table, small signed values (~±1000) — a trained
                     classifier / coefficient set, never decompiled
0x138000..0x144000   code, H=1.27 (extremely repetitive — table-driven)
0x148000..0x210000   data
0x210000..0x211300   monotone byte ramps = gamma / tone-curve LUTs
0x217AEC..0x21DB28   >>> the entire diagnostic string pool
0x21E098             end
```

The `0x110000` block of little-endian s32s is the most interesting
undecomposed region: it is the right size and shape for classifier weights.

---

## 7. Tooling built for this

A **TI C6000 disassembler now exists on this machine** — binutils 2.42
(the copy already vendored for the M32R work) configured `--target=tic6x-elf`:

```
work/c6x-tools/build/binutils/objdump -D -b binary -m tic6x \
    --adjust-vma=<base> work/dsp/CV4T_dsp.bin
```

**Honesty note on the disassembly.** The decoder is upstream binutils, so the
*instruction tables* are trustworthy, but it has **not** been validated against
a known entry point in this image the way `DISASM_BRIEF.md` §Rules demands, and
a flat `-D` sweep has no idea where instructions begin. What is claimed in §3 is
only the **statistical contrast** (p-bit framing, code vs data), which is
measured and reproducible. **No individual instruction listed by this tool
should be trusted until recursive-descent from a real entry point is done.**

Unsolved: the DSP image's **load base**. Pointer-voting against string starts
gives a weak spread over `0x8091F000..0x80958000` (best `0x80958000`, only 37
distinct hits) — DDR2 on a DM6437 does start at `0x80000000`, so the range is
right, but this is **not** a solved number and no address in §6 should be
treated as a memory address. File offsets only.

---

## 7a. Public TI material for this DSP

The DM6437 is a standard, publicly documented TI part, so the *platform* side
of this firmware is fully specified in vendor documentation. Only Continental's
application code is proprietary. All links below were checked live (HTTP 200,
no login wall) at the time of writing.

### What the firmware actually uses — measured, not assumed

Searching the plaintext for library fingerprints:

| fingerprint | result |
|---|---|
| `MSGQ:` `POOL:` `GIO_create` `TSK_*` `QUE_put` `IOM_READ/WRITE` `SYS_error` | **present** |
| `VLIB` / `VLIB_*` | **absent** |
| `IMGLIB` / `IMG_*`, `DSPLIB` / `DSP_*` | **absent** |
| `Codec Engine`, `XDAIS`, `IUNIVERSAL`, `ACPY3`, `DMAN3`, `ti.sdo` | **absent** |
| `EDMA` (`0x21DAE9`, in `VideoEDMA`) | present |

So the RTOS is **DSP/BIOS 5.x** (the `MSGQ`/`POOL`/`GIO`/`TSK`/`IOM` API set is
its signature), driving the **VPFE/CCDC** capture path and **EDMA** — exactly
the DVSDK driver stack. But the vision code is **hand-written, not VLIB**: the
`Canny` stage in the pipeline is Continental's own (`SRCS*`/`SRN*`/`SRFS*`
symbols), not `VLIB_nonMaximumSuppressionCanny` et al.

That matters for reverse engineering: **you cannot fingerprint-match VLIB
binaries against this image to identify functions.** The library-identification
shortcut is not available. Note the absence of these strings proves the *names*
aren't there; a statically-linked copy with symbols stripped would not show up
this way, so this is strong but not absolute.

### Most useful documents

| Doc | What it gives you |
|---|---|
| **SPRU732** C64x/C64x+ CPU and Instruction Set Reference | The instruction encodings. Needed to validate any disassembly — this is the ground truth for §7. |
| **SPRS345D** DM6437 datasheet | Memory map, DDR2 at `0x80000000`, peripherals, the **HECC CAN controller** |
| **SPRUFE8** C6000 EABI / **SPRU186** assembly tools | Object format, section layout, how the linker lays out an image |
| **SPRUEM0 / SPRUE38** VPSS, VPFE/CCDC | The capture path behind `/CCDC`, `TSK_ccdc`, the `VSYNC` messages |
| **SPRU403** DSP/BIOS API | `MSGQ`, `POOL`, `GIO`, `TSK` semantics — the exact strings in §4 |
| **SPRAB78** Canny on C64x+ using VLIB | Reference implementation of the *same algorithm* our `Canny` stage runs |
| **SPRY302** TI ADAS whitepaper | LDW/OD/SFM mapping on TI silicon — architectural context |

```
https://www.ti.com/lit/ug/spru732j/spru732j.pdf     instruction set  <- most valuable
https://www.ti.com/lit/ds/sprs345d/sprs345d.pdf     DM6437 datasheet
https://www.ti.com/lit/ug/sprufe8b/sprufe8b.pdf     EABI
https://www.ti.com/lit/ug/spru198k/spru198k.pdf     programmer's guide
https://www.ti.com/lit/an/sprab78/sprab78.pdf       Canny via VLIB
```

### SDK / libraries

* **VLIB 3.3.2 (legacy)** — 40+ royalty-free C64x+ vision kernels, still
  directly downloadable, no TI login:
  `https://software-dl.ti.com/libs/vlib/3_3_2_0-legacy/index_FDS.html`
  The C64x+ Linux installer (`vlib_c64Px_obj_3_3_2_0_Linux.bin`) is a real
  UPX-packed i386 ELF; verified by fetching its first 2 MB. **Binary-only
  release** — no kernel source. Useful as a *behavioural* reference for what
  each pipeline stage should compute, not for symbol matching (see above).
* **DVSDK for DM6437** — the BIOS-based DVSDK v1.11 is the environment this
  firmware was built against (DSP/BIOS + CCS + CSL + VPFE drivers). TI's
  current pages push the *Linux* DVSDKs for DM355/DM6446/DM6467, which are the
  wrong branch; the DM6437 BIOS DVSDK lives in TI's target-content archive and
  is the one to look for.
* **CCS v3.3/v4** was the era's IDE. Modern CCS still ships the C6000 codegen
  tools, which is a cleaner way to get an assembler/linker if you only need to
  *build* C6000 code rather than reproduce the original toolchain.
* Hardware: the **DM6437 EVM / DVDP** (Spectrum Digital) is the reference board
  and appears on the used market — relevant only if you want to run code.

### The honest limit

None of this recovers Continental's algorithm. It gives you the **platform**:
what the instructions mean, how the RTOS calls work, what the capture pipeline
does, and what a competent Canny/Kalman implementation looks like for
comparison. The lane logic itself still has to come out of the disassembly.

---

## 8. Can it be modified?

**The container is fully reconstructible** — but this block should still be
treated as do-not-flash for now.

* Layers we can rebuild: inner `clen`/`ulen`/both CRC-32s, outer BootNfo
  CRC-32, block CRC-16, file CRC-32. All verified.
* **The OEM zlib stream is not byte-reproducible.** OEM `0x172399`; best local
  attempt (wbits=11, level 6) `0x160910` — 72,460 bytes *smaller*. The OEM
  used a different deflate implementation. So a rebuilt part will differ from
  OEM everywhere, and `vbftool diff` loses all power as an acceptance test —
  the §5 acceptance discipline in the `vbf-firmware-container` skill cannot be
  applied.
* Size is not a blocker (the erase region is fixed at `0x1724BC` and a rebuild
  is smaller; it can be zero-padded back to length).
* **Unknown and untested:** whether the DSP image carries its *own* internal
  integrity word inside the plaintext, the way the EXE does
  (`EXE_integrity_monitor.md` — CRC-32C at `end-7`). The string
  `Checksum of CODE SEG %2x ` at `0x21B443` says **it probably does**.
  That must be found before any flash. Per the skill's §4 rule: *do not flash a
  modified block whose internal word you cannot recompute.*

---

## 9. What this changes

1. **`IPMA_module.md` §2 and `DISASM_BRIEF.md` §Architecture must be corrected**
   — "not directly-executable M32R … do not attempt to disassemble it" sent the
   whole effort away from a block that opens with `zlib.decompress`.
2. **The IPMA is two processors.** The M32R is the housekeeping/CAN/diagnostic
   host; the DM6437 does the vision. The lane algorithm was never in the block
   we patched — the calibration only *gates* a result the DSP produces.
3. **The Jaccard-0.000 result in `F1FT_vs_CV4T_compatibility.md` is an
   artefact** of comparing two compressed streams; it says nothing about how
   similar the programs are. The comparison should be redone on the plaintexts
   now that they exist. (The conclusion "don't mix generations" may well
   survive — but its stated evidence does not.)

### Next, in value order

1. Find the internal checksum (`Checksum of CODE SEG`) — gates everything else.
2. Re-run the cross-generation diff on the three decompressed images.
3. Check `LDSpeedSensor` for an independent DSP-side speed gate.
4. Solve the load base, then recursive-descent disassembly from the vector
   table at `0x0`.
5. Decompose the `0x110000` coefficient table.
6. Look for the `TSK_MON` UART console — a live debug channel on the bench
   would beat static analysis for everything above.

---

## Reproduce

```bash
cd /home/gl/Projects/ford/IPMA/Research
python3 work/dsp/unwrap_dsp.py --selftest     # 12 header fields, 3 generations
python3 work/dsp/unwrap_dsp.py CV4T-14F397-BF.VBF -o work/dsp/
```
