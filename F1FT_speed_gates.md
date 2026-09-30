# F1FT IPMA LKA/LCA speed-lowering patch — reference

Self-contained recipe for lowering the LKA and LCA activation speeds on the
**F1FT** IPMA calibration (`F1FT-14F398-AG`, release 4.93.06, Continental CSF2F0
platform). This is the F1FT counterpart to the CV4T work in
[`IPMA_speed_gates.md`](IPMA_speed_gates.md).

> **Status: patched artifacts rebuilt after the U2101 root cause was found and
> fixed.** The three integrity layers that a value edit invalidates are solved
> and recomputed — including the `BootNfo +0x1C` metadata digest, whose omission
> was what made the earlier builds latch `U2101-00` in the IPMA. See §4.

Tool: [`work/patch_thresholds_f1ft.py`](work/patch_thresholds_f1ft.py) (43
self-tests). Built artifacts: `F1FT-14F398-AG_LKA40_LCA45.VBF`,
`F1FT-14F398-AG_LKA40_LCA45_HOLD12.VBF`.

---

## 1. Container and block layout

```
VBF        F1FT-14F398-AG.VBF   DATA part, ecu_address 0x706, vbf 2.3
block0     load 0x00902000  len 0x640D   (external CS-window flash, off-chip)
BootNfo    descriptor at block offset 0 (shorter than CV4T, no A.D.C. label):
             +0x00 "BootNfo\0"
             +0x08 format word 0x00742916   (CV4T/BM5T = 0x006C2916; NOT a checksum)
             +0x0C magic 0xAA5AA555
             +0x10 start 0x00902000
             +0x14 end   0x0090840C   (declared span 0x640C = block len − 1)
             +0x18 ALGORITHM TAG 0x340BC6D9 = ~crc32("123456789")  (fixed, §4)
             +0x1C METADATA DIGEST 0xBFEB7F98                      (§4 — MUST be
                   recomputed; leaving it stale sets U2101-00)
             +0x28 "CSF2F0"           (platform; CV4T = "CSF265")
```

Unlike CV4T (tagged region index + element-size table), F1FT uses a **flat
30-row index** at block offset `0x74`, each row 12 bytes:

```
[ block_offset : u32 BE ][ flags = 0x000C0100 : u32 ][ region_hash : u32 BE ]
```

(The earlier note "28 rows at `0x8C`" was wrong and made the patcher skip rows
0/1. The row count is now derived by scanning the flags word, and `-AE`/`-AF`
have 26 rows — never hard-code it.)

The 30 regions tile the block from row 0's offset (`0x1DC`) to the declared end,
the last region ending at `0x640C`. Region sizes: the eleven `0x624` per-variant
blobs start at `0xE24`; earlier rows and rows 11+ are smaller records
(`0x35C`, `0x3F8`, `0x10`/`0x30`, `0xC8`). Only `[0..0x1DC)` — the descriptor and
the index itself — lies outside every region hash, and that gap is exactly what
the `+0x1C` digest covers.

---

## 2. Where the thresholds live (structurally, per variant)

Derived from the index, not hard-coded. Fields are big-endian float32 in km/h,
`[arm @ +off, band @ +off+0x10]`, drop-out = `arm − band` (no stored disengage
constant — identical encoding to CV4T).

| Gate | field offset within each `0x624` region | OEM value |
|---|---|---|
| **LKA arm (A)** | region `+0x080` | region0 = **64.6** km/h; regions 1–10 = 60.6 / 61.0 |
| **LKA band (A)** | region `+0x090` | 5.0 |
| **LKA arm (B)** ⚠ | region `+0x334` | **same as A** (64.6 / 60.6 / 61.0) |
| **LKA band (B)** | region `+0x344` | 5.0 |
| **LCA arm**  | region `+0x598` | **80.0** km/h (all 11 regions) |
| **LCA band** | region `+0x5A8` | 5.0 |

> **⚠ The LKA gate is stored TWICE per region — this was the F1FT porting bug.**
> Each `0x624` region carries two parallel arm/band sub-records: **A** at `+0x080`
> `[arm, 37.04, 191, upper=119.5, band]` and **B** at `+0x334`
> `[arm, 37.04, 173, upper=110.0, band]`. On the stock file both hold the same
> arm (64.6/60.6/61.0). This is the F1FT hoist of the CV4T two-table pair
> (`0x30A01048` + `0x30A01058`) into a single region — and the CV4T tool patched
> **both** tables. The first F1FT port wrote only copy **A**; the bench result
> was **engage unchanged at ~65 km/h, disengage dropped to ~40 km/h**. That
> asymmetry pins the roles: **sub-record B (`+0x334`) governs the engage
> transition**, A governs the drop-out. The tool now patches both.

Region 0 is the high/LKA-equipped variant (its `64.6` matches the CV4T live
variant). The runtime variant selector is unknown (same open question as CV4T),
so **every variant copy is patched** so whichever the module selects is lowered.

**m/s copy of the LKA gate** — the standalone table at mem `0x9080F4` (file
`0x60F4`), 16-byte rows `[suppress_m/s, arm_m/s, 68.0, 70.0]`:

```
row2 @ file 0x6114 (mem 0x908114):  16.670  17.940  68.0  70.0   <- LKA
```

This row is the F1FT hoist of CV4T's `tag38 rec2 +0x1C0/+0x1C4`. It sits inside
index region 17, so editing it recomputes that region's hash too. The tool keeps
it consistent with the km/h edit (arm/3.6, suppress = (arm−band)/3.6).

The `16.67/17.94` pair appears at **index 2 in the same ordered variant list**
in both CV4T (2015-era, 4.27.0) and F1FT (4.93.06) — cross-version corroboration
that survived the container rewrite.

---

## 3. Integrity — three layers to repair, in this order

### Layer 1 — per-region hash (**SOLVED**, the layer a value edit breaks)

Each 30-row index entry stores a digest of its region:

```
region_hash = ~zlib.crc32(region_bytes) & 0xFFFFFFFF
```

i.e. a standard reflected CRC-32 (poly `0xEDB88320`, init `0xFFFFFFFF`) **without
the final XOR-out**. Verified reproducing **30/30** stored hashes on the stock
file. Confirmed against the firmware: the app's CRC-32 core at `0x0A8B50` takes
the init in a register and the caller applies (or omits) the final `not`; the
runtime calibration validator (`0x15D94` → streams each region) uses exactly
this `~crc32` form. Repeated hash values in the stock index (rows 4≡5, 6≡8, 3≡9,
12≡13≡14, 19–23) correspond to byte-identical regions — an independent check.

### Layer 2 — BootNfo `+0x1C` metadata digest (**SOLVED**, §4)

```
meta_digest = reflected CRC-32 (poly 0xEDB88320), init 0x3F81FACB, NO final XOR,
              over block[0x20 : end_of_index]
```

It covers the whole region index, so **every layer-1 hash is inside its span** —
recompute it *after* layer 1, never before. This is the layer the earlier builds
missed; see §4 for how it was found and what it broke.

### Layer 3 — container (handled by the VBF tooling)

Per-block CRC-16/CCITT-FALSE, then header `file_checksum` CRC-32. Same as any
VBF; `patch_thresholds_f1ft.py` recomputes both and `vbftool verify` confirms.

---

## 4. The BootNfo `+0x18` / `+0x1C` pair — SOLVED (and the U2101 root cause)

### What went wrong

Both `F1FT-14F398-AG_LKA40_LCA45.VBF` and `..._HOLD12.VBF`, as built by the
earlier tool, flashed successfully and then made the IPMA latch

```
U2101-00   raw E10100   status 0x08   [confirmedDTC]
```

— `Control Module Configuration Incompatible` — which would not clear until an
OEM calibration was flashed back. `U2101-00` is in the module's own DTC table at
app `0xD9882` (`E1 01 00 FF 00 0F`), immediately after `U2100-00`, in the block
of configuration/compatibility codes. The module accepted the *download* and
then rejected the *dataset*.

Cause: the earlier tool left `BootNfo +0x1C` stale.

```
F1FT-14F398-AG_LKA40_LCA45.VBF        stored 0xBFEB7F98   correct 0xE2CA9AB1
F1FT-14F398-AG_LKA40_LCA45_HOLD12.VBF stored 0xBFEB7F98   correct 0xA785BD89
```

Both builds carried the **OEM** digest while their region index had changed, so
both faulted — which also retires the previous explanation. The
`+0x4CC` hold-bound theory was blamed for the HOLD12 failure, but the gates-only
build never touched a bounded field and failed **identically**, so the bound was
never the discriminator. It is demoted to *unproven but still enforced by the
tool* (conservative: the invariant `hold <= companion` holds across every OEM
generation, and clamping costs nothing).

### Why it was missed: `+0x18` is not a checksum at all

`+0x18 = 0x340BC6D9` resisted every sweep — exhaustive `(start,end)` × poly ×
init × xorout, CRC-32C, GF(2) init-solving, hash-of-hashes, digest truncations —
because **there is no span to reproduce**:

```
0x340BC6D9 == ~zlib.crc32(b"123456789") & 0xFFFFFFFF
```

That is the CRC-32 **check value**, the standard algorithm self-test constant.
It is a fixed *algorithm tag* declaring which CRC the container uses. Confirming
evidence: it is byte-identical in F1FT `-AE`, `-AF` and `-AG` even though those
are different datasets of different lengths, and a scan of every IPMA image on
disk (CV4T, BM5T, BK2T, F1FT, JX7T, N1BT, LB5T, H1BT, all app/DSP/SBL/cal parts)
finds the constant **only** at this one offset in the three F1FT calibrations.

The real digest sits in the next word, `+0x1C`, which was never examined — and
unlike `+0x18` it *does* vary per dataset:

```
F1FT-14F398-AE  +0x18 340BC6D9   +0x1C 17BEB5E8
F1FT-14F398-AF  +0x18 340BC6D9   +0x1C 8FE36537
F1FT-14F398-AG  +0x18 340BC6D9   +0x1C BFEB7F98
```

### How `+0x1C` was solved

`-AE` and `-AF` are **the same length** (19277 B), which makes CRC linearity
usable directly. For any CRC-32-shaped engine over a fixed span,
`crc(A) ^ crc(B) = L(A ^ B)` with **init and xorout cancelling**, so the span
must satisfy

```
crc_{init=0, no xorout}( (A^B)[start:end] )  ==  stored_A ^ stored_B
```

That single test eliminates init, xorout and endianness at once.
[`work/f1ft/crack_w1c_linear.c`](work/f1ft/crack_w1c_linear.c) ran it over every
`(start,end)` × three engines: **every surviving candidate ended at `0x1AC`** —
exactly the end of the 26-row index. GF(2) init-solving on all three images then
left one init consistent across all three, and only for `start == 0x20`:

```
init 0x3F81FACB  over [0x20 : end_of_index]  ->  AE 17BEB5E8  AF 8FE36537  AG BFEB7F98
                                                 3/3 stock words reproduced
```

`start = 0x20` is the byte immediately after the digest slot, and the end is the
end of the index — a self-consistent, structurally meaningful span, not a fitted
coincidence. The AG file is an **independent confirmation**: it has 30 index
rows, not 26, so its span length differs, yet the same init reproduces it.

Honest bound on this result: the span/init were derived from the images, not
from the verifier's disassembly. The claim that it *reproduces stock on 3/3 OEM
datasets with a structurally meaningful span* is solid; the claim about which
routine reads it is not traced. What promotes it past the earlier `+0x4CC`
theory is that it explains **both** failed builds, including the one that
touched no bounded field.

---

## 5. Build and verify

```bash
cd /home/gl/Projects/ford/IPMA/Research
python3 work/patch_thresholds_f1ft.py --selftest            # 43 checks
python3 work/patch_thresholds_f1ft.py --lka-arm 40 --lca-arm 45 --dry-run
python3 work/patch_thresholds_f1ft.py --lka-arm 40 --lca-arm 45 \
        -o F1FT-14F398-AG_LKA40_LCA45.VBF

T=~/.hermes/skills/software-development/vbf-firmware-container/scripts/vbftool.py
python3 $T verify F1FT-14F398-AG_LKA40_LCA45.VBF
python3 $T diff   OEM/F1FT-14F398-AG.VBF F1FT-14F398-AG_LKA40_LCA45.VBF
```

The `40/45` build's diff is **fully accounted**: value-edit bytes across 35
float sites (22 LKA arm = 11×A `+0x080` + 11×B `+0x334`, 11 LCA `+0x598`, 2 m/s)
+ 12 region-hash words + the `+0x1C` metadata digest + the header file_checksum
and block CRC-16 outside the block = **109 changed bytes, zero unexplained**.
`+0x18` verified identical (`0x340BC6D9`); `+0x1C` recomputed
`0xBFEB7F98 -> 0xE2CA9AB1`.

Three self-tests guard the regression specifically: the `+0x1C` recipe must
reproduce the stock word on **all three** OEM F1FT calibrations, the patched
output's digest must differ from OEM, and `verify()` must *report* a
deliberately-staled digest.

---

## 6. Safety

Same envelope as the CV4T modification: LKA/LCA engage in a speed range Ford
never validated, the gain schedule ramps from zero (so *less* authority at lower
speed), the system stays overridable, and the applied steering authority is not
measurable from CAN. Treat as an evaluation configuration. Reverting is a single
flash of the untouched `OEM/F1FT-14F398-AG.VBF`.

**F1FT-vs-CV4T hardware caveat still stands** (see
[`F1FT_vs_CV4T_compatibility.md`](F1FT_vs_CV4T_compatibility.md)): the F1FT set
is a CSF2F0 build. Flash the F1FT calibration only onto an F1FT-core (CSF2F0)
module, never cross-flash it onto the CV4T (CSF265) vehicle under study.
