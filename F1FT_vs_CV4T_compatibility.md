# Is the F1FT IPMA firmware set compatible with CV4T hardware?

Question: the vehicle under study runs the **CV4T** software set (rel 4.27.0) on an
IPMA whose core assembly reads `F111 = CV4T-14F403-AF`. Would the **F1FT** set
(rel 4.93.06) run on that same module?

Method: container parse (`vbftool info/extract`) of all four parts of each
generation plus the BM5T (rel 4.5.5) set as a third control, then static
comparison of the extracted images — MCU/platform tags, peripheral and RAM
constant footprints, flash/erase maps, integrity descriptors — plus the
as-built corpus in `/home/gl/Projects/ford/ab` as field ground truth.

**Verdict: partially. The MCU and its low-level environment are the same, but
the F1FT set is built for a different camera platform variant (CSF2F0 vs
CSF265) and cannot be treated as a drop-in. Only the SBL is provably
interchangeable.**

---

## 1. What is provably identical (hardware-level)

| Evidence | Result |
|---|---|
| **SBL block** `14F399` | `CV4T-14F399-AF`, `F1FT-14F399-AD`, `BK2T-14F399-AD/AE` all extract to the **same 4912-byte image**, sha256 `91bd7aaa7abd1fbe65c96a84db2453c22e1b3f190029cc9bf7cef8750e974ce5`. Only the VBF header part number differs. |
| MCU | `M32192` string in the SBL and in every application image. Same Renesas M32R part in all three generations. |
| Flash driver | `SuperFlash` sector table in the SBL: identical `0x2000/0x3000/0x4000/0x8000/0x10000 … 0xF0000` boundary list. Same flash device geometry. |
| Peripheral window | `LD24`/`SETH` constant footprint over `0x8040xx–0x8044xx` present in all three; no F1FT-only *peripheral page* appears (the diffs at `0x80E000/0x811000/0x818000/…` are RAM/data pages, not SFR pages). |
| RAM extent | Highest RAM constant `0x8FB2C7` — **identical** in CV4T, BM5T and F1FT. Same RAM size. |
| Memory-permission tables | The two in-image range tables (CV4T `img+0x0C0618` / `img+0x0C6F30`, F1FT `img+0x0C4704` / `img+0x0CAFFC`) are **byte-identical**: `0–0x1FFF`, `0x4000–0xFFFF`, `0x804000–0x81FFFF`, `0x10000–0x1FFFF`, `0x10000–0x2FFFF`, `0x2000–0x21FF`, `0x3000–0x31FF`, `0–0xFFFFF`. Same flash/RAM map described by both. |
| Diagnostics | Both `ecu_address = 0x706`, CAN_HS, CAN_STANDARD, same `sw_part_type` per slot. |
| Source tree | Same Continental `csf2xx` sources (`bootinfo.c`, `fimprocessing.c`, `halevt.c`, `ocsci.c`, `sysswinit.c`). CV4T additionally contains `xcp.c`; F1FT does not. |

The identical SBL is the strongest single fact here: the flash driver that the
OEM tool uploads to RAM and executes is **the same binary** on both
generations, so the MCU, its clocking and its flash controller are the same
silicon.

## 2. What is different (and blocks a drop-in)

| Item | CV4T (4.27.0) | BM5T (4.5.5) | F1FT (4.93.06) |
|---|---|---|---|
| **Platform tag in BootNfo** | `CSF265` | `CSF265` | **`CSF2F0`** |
| App erase region | `0x00020000` len `0xDCB08` | `0x00020000` len `0xDAFE0` | **`0x00010000` len `0xE4E38`** |
| Calibration load | `0x00003000` len `0x4428` | `0x00003000` len `0x3C18` | **`0x00902000` len `0x640D`** |
| Calibration index format | tagged region index, 10 rows, `0x408` records | same | flat 28×12-byte array, `0x3F8` records, no tag table |
| BootNfo descriptor | full, `A.D.C._CRCst` label at +0x10, CRC at +0x24 | same | **shorter by 0xC**, no label, CRC at +0x18 |
| BootNfo CRC algorithm | `zlib.crc32`, 4 CRC bytes skipped — **solved** | solved | **not reproduced** (exhaustive sweep, CV4T passed as control) |
| DSP image similarity to CV4T | — | Jaccard **0.004** | Jaccard **0.000** |
| App image similarity to CV4T (16-byte shingles) | — | 0.562 | **0.409** |

The platform tag is the decisive one. `CSF265` and `CSF2F0` are two different
members of Continental's CSF2xx camera family; the tag is written into every
BootNfo descriptor of the set and into the DSP part. The **DSP application has
essentially zero content in common** between the two generations (Jaccard
0.000) — that is the imager/vision pipeline, i.e. exactly the part that is
bound to the sensor and optics.

Note a subtlety: the F1FT application image at `0xC9EBE` still carries a
`CSF265` string in a data pool, while its BootNfo says `CSF2F0`. So the
application is built for a *family* that includes both; the descriptor declares
the *board*. Do not read the stray `CSF265` as evidence of compatibility.

## 3. Field ground truth (as-built corpus)

Every IPMA in `/home/gl/Projects/ford/ab` pairs software with core assembly
consistently — **no vehicle mixes the two**:

```
F111 CV4T-14F403-AF  ->  F188 CV4T-14F397-AF  F120 CV4T-14F397-BF  F124 CV4T-14F398-AF   (1 vehicle)
F111 F1FT-14F403-AE  ->  F188 F1FT-14F397-AG  F120 F1FT-14F397-BE  F124 F1FT-14F398-AG   (5 vehicles)
F111 BM5T-14F403-AG  ->  BM5T set                                                        (Kuga2 logs)
```

(The `14F403-xx` string embedded *inside* each application — `CV4T-14F403-AE`
in the CV4T app, `BM5T-14F403-AA` in the F1FT app — is a build-time reference,
**not** the reported `F111`: the observed vehicles report `-AF` and
`F1FT-14F403-AE` respectively. It is not usable as a compatibility key.)

## 4. Part-by-part assessment

| F1FT part | On CV4T hardware | Confidence |
|---|---|---|
| `F1FT-14F399-AD` SBL | **Compatible** — byte-identical payload to `CV4T-14F399-AF` | proven |
| `F1FT-14F397-AG` app | Plausible at the MCU level (same core, SFRs, RAM, and the target region `0x10000–0x1FFFF` is declared in CV4T's own map) — but it is a `CSF2F0` build and is useless without its own DSP part and calibration | unproven, **do not flash alone** |
| `F1FT-14F398-AG` calibration | **Not usable with the CV4T application**: different load address (`0x902000` vs `0x3000`) and different index format. Also its integrity word cannot be recomputed | proven incompatible with CV4T app |
| `F1FT-14F397-BE` DSP | Different vision build for a different camera board (0.000 content overlap) | highest risk |

The set is **atomic**: you cannot mix an F1FT application with a CV4T
calibration, because the application/calibration contract moved from `0x3000`
to `0x902000` between generations. A cross-generation flash means flashing all
three programmable parts, which means betting the module on the `CSF2F0`
DSP/imager build matching a `CSF265` board.

One positive datum for the `0x90xxxx` region: **both** generations' DSP parts
write 16-byte software stamps to `0x00900048` and `0x00901EB0` (CV4T writes
`"CV4T-14F397-BF"`, F1FT writes `"F1FT-14F397-BE"`), so that flash device
exists and is writable on CV4T hardware. Whether it extends to
`0x902000..0x90840C` (25 KB) is **not** established from these files.

## 5. Practical consequence for this project

Even if an F1FT flash took, it would be a **regression for the modification
work**:

- The LKA/LCA speed gates are patched in the **calibration** part. On CV4T the
  BootNfo CRC-32 is solved and a patched part has been flashed and validated on
  the road (40.04 / 34.91 km/h LKA, 45.09 / 39.94 km/h LCA).
- On F1FT the BootNfo integrity word is **not reproducible**, so no modified
  F1FT calibration can currently be built. Moving to F1FT gives up the working
  modification with nothing to replace it.

## 5a. What CSF2xx is, and what documentation exists

`CSF2xx` is **not** a public product family and has **no datasheet**. It is the
internal platform/board designator of the module's supplier — Continental's
camera business, historically **ADC Automotive Distance Control Systems GmbH,
Peter-Dornier-Str. 10, Lindau (Bodensee)**, which is exactly the `A.D.C.`
in the `A.D.C._CRCst` BootNfo label. Public Continental material names camera
*products* (MFC2 … MFC500/MFC52x) but never the `CSFxxx` board codes; searches
for `CSF265`, `CSF2F0` and `csf2xx` return nothing automotive. Treat the tag as
an internal build target only — its meaning here is established from our own
corpus, not from any document:

```
CSF265  ->  BM5T (4.5.5), CV4T (4.27.0), BK2T   (all 14F403-xx cores of that era)
CSF2F0  ->  F1FT (4.93.06)
```

(Checked across every IPMA VBF on this machine. Note `BK2T-14F397-AE/-BE/-AE`
in `CalibrationFiles/` are **the CV4T parts under a different file name** —
their `sw_part_number` fields read `CV4T-14F397-AF` / `-BF` / `14F398-AF` and
the payloads match; they are not a fourth generation.)

### The MCU, by contrast, is fully documented

The `M32192` string in every image is a real, publicly documented part:
**Renesas (ex-Mitsubishi) M32192, M32R/ECU series, M32R-FPU core** — announced
July 2004, now obsolete.

| Spec | Value |
|---|---|
| Core | M32R-FPU, 32-bit RISC, **160 MHz** |
| Flash | **1 MB**, `0x00000000–0x000FFFFF` |
| Internal RAM | **176 KB**, `0x00804000–0x0082FFFF` |
| SFRs | from `0x00800000` |
| Package / I-O | 144-pin LQFP, 16×10-bit ADC, **2× full CAN 2.0B**, SIO, DRI |
| Supply / temp | 3.3 V / 5 V, −40…+85 °C |

Documents:

- 32192/32195/32196 Group **Hardware Manual** (REJ09B0123, Rev 1.10) —
  https://www.renesas.com/en/document/mas/321923219532196-group-hardware-manual
- Product page (obsolete): https://www.renesas.com/en/products/32192
- **M32R-FPU Software Manual** (instruction set incl. the FPU opcodes binutils
  cannot decode): https://www.renesas.com/en/document/mas/m32r-fpu-software-manual
- M32R Family Software Manual: https://www.renesas.com/en/document/mas/m32r-family-software-manual
- 2004 launch note: https://phys.org/news/2004-07-renesas-technology-m32192-group-microcontrollers.pdf

**The manual's map is confirmed by the images**, which is a useful independent
check on this project's memory map:

- highest internal-RAM `LD24` reference is exactly `0x0082FFFF` in CV4T, BM5T
  **and** F1FT — the top of the M32192's 176 KB RAM, identical in all three;
- SFR references cluster in `0x800000–0x803310`, inside the documented SFR block;
- the in-image permission table's `0x0–0xFFFFF` entry is exactly the 1 MB
  internal flash, and `0x804000–0x81FFFF` is inside internal RAM;
- everything at `0x200000` (DSP app) and `0x90xxxx` (F1FT calibration, and the
  16-byte software stamps both generations write) lies in the M32192's
  **external extension area** (`CS0–CS3`, wait-controller managed) — i.e. those
  live on separate off-chip memory devices on the camera board.

That last point sharpens the compatibility question: the F1FT calibration at
`0x902000` targets an **external** memory device, so whether it exists and is
25 KB deep on a CSF265 board is a board-level question the MCU manual cannot
answer — only a read from the module can.

## 6. What would settle it

1. Read `F111` / `F113` from the target module (`0x706`) — if it is a
   `CV4T-14F403-*` core assembly, the module is a `CSF265` board and the F1FT
   set is for different hardware.
2. Probe the OEM tool's own compatibility gate: the flasher reads `F113`+`F188`
   before download. A real Ford tool offered the F1FT set against a
   CV4T-core module is the cheapest authoritative answer.
3. Before any attempt, dump `0x902000..0x908FFF` from the CV4T module over the
   SBL read path to confirm that flash region physically exists and is large
   enough.

**Recommendation: do not cross-flash.** The only interchangeable part is the
SBL, which is already identical and therefore pointless to swap. Keep the CV4T
set, where the integrity layer is solved and the modification is proven.
