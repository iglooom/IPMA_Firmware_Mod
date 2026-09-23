# F1FT IPMA LKA/LCA speed-lowering patch — reference

Self-contained recipe for lowering the LKA and LCA activation speeds on the
**F1FT** IPMA calibration (`F1FT-14F398-AG`, release 4.93.06, Continental CSF2F0
platform). This is the F1FT counterpart to the CV4T work in
[`IPMA_speed_gates.md`](IPMA_speed_gates.md).

> **Status: patched artifact built and statically verified; NOT yet bench/road
> validated.** The two integrity layers that a value edit invalidates are
> solved and recomputed. A third top-level word (`BootNfo +0x18`) is left
> unchanged — see §4 for why that is believed safe and what must confirm it.

Tool: [`work/patch_thresholds_f1ft.py`](work/patch_thresholds_f1ft.py) (17
self-tests). Built artifact: `F1FT-14F398-AG_LKA40_LCA45.VBF`.

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
             +0x18 top integrity word 0x340BC6D9   (see §4 — left unchanged)
             +0x28 "CSF2F0"           (platform; CV4T = "CSF265")
```

Unlike CV4T (tagged region index + element-size table), F1FT uses a **flat
28-row index** at block offset `0x8C`, each row 12 bytes:

```
[ block_offset : u32 BE ][ flags = 0x000C0100 : u32 ][ region_hash : u32 BE ]
```

The 28 regions tile the block from row 0's offset (`0xE24`) to the declared end
(`0x640C`). Region sizes: rows 0–10 are `0x624` per-variant blobs, row 11 is
`0x35C`, rows 12–14 are `0x3F8`, rows 15–24 are small (`0x10`/`0x30`), rows
25–27 are `0xC8`. The gap `[0..0xE24)` (descriptor + index + a pool of loose
float parameters) is **not** covered by any region hash.

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

## 3. Integrity — two layers to repair, in this order

### Layer 1 — per-region hash (**SOLVED**, the layer a value edit breaks)

Each 28-row index entry stores a digest of its region:

```
region_hash = ~zlib.crc32(region_bytes) & 0xFFFFFFFF
```

i.e. a standard reflected CRC-32 (poly `0xEDB88320`, init `0xFFFFFFFF`) **without
the final XOR-out**. Verified reproducing **28/28** stored hashes on the stock
file. Confirmed against the firmware: the app's CRC-32 core at `0x0A8B50` takes
the init in a register and the caller applies (or omits) the final `not`; the
runtime calibration validator (`0x15D94` → streams each region) uses exactly
this `~crc32` form. Repeated hash values in the stock index (rows 4≡5, 6≡8, 3≡9,
12≡13≡14, 19–23) correspond to byte-identical regions — an independent check.

### Layers 2 & 3 — container (handled by the VBF tooling)

Per-block CRC-16/CCITT-FALSE, then header `file_checksum` CRC-32. Same as any
VBF; `patch_thresholds_f1ft.py` recomputes both and `vbftool verify` confirms.

---

## 4. The BootNfo `+0x18` top word — unsolved, left unchanged, believed safe

`+0x18 = 0x340BC6D9` is **not reproduced** by any standard CRC over any
contiguous span. Exhausted (all under `work/f1ft/`):

* reflected CRC-32 (`0xEDB88320`) over **every** `(start,end)` sub-range, whole
  / crc-word-skipped / crc-word-zeroed, both endiannesses, init/xorout free —
  zero hits (`crack_bootnfo.c`);
* forward CRC-32 (`0x04C11DB7`) and CRC-32C (`0x82F63B78` — the app's second CRC
  table) over all ranges — zero hits (`crack_c.c`);
* a catalogue of 18 known 32-bit polynomials, then a partial all-65536-poly
  sweep — only coincidental hits at random ranges (`crack2/3/4/5.c`);
* GF(2) init-solving for every plausible span — every solved seed is
  meaningless (not the length, address, part number, or a neighbour), so it is
  **not** a seeded contiguous CRC;
* hash-of-hashes / index-table encodings, digest truncations (MD5/SHA1/SHA256),
  sum/xor accumulators, word-swapped and flash-size-padded variants — none.

**Why the patch does not touch it and this is believed safe:**

1. Every edit this tool makes lands **inside a per-region-hashed region** (LKA/
   LCA fields in the `0x624` regions; the m/s row in region 17). The metadata
   gap `[0..0xE24)` — the only data `+0x18` can plausibly cover, since everything
   else already has a region hash — is **not modified**, so the stored `+0x18`
   stays consistent with what it protects.
2. The app's runtime descriptor validator (`0x15D94`) checks the magic at
   `+0x0C` and streams the per-region `~crc32` hashes; **no runtime read/compare
   of `+0x18` was found**. This points to `+0x18` being an OEM download-tool
   integrity word rather than a boot check.

**This is an inference, not proof.** Before relying on the flash, confirm on the
bench that the module accepts and runs the patched part through a soak cycle
(delayed-integrity check), exactly as the CV4T part was validated. If the OEM
tool or bootloader rejects it on `+0x18`, that word's algorithm must be read out
of the SBL/download path before proceeding.

---

## 5. Build and verify

```bash
cd /home/gl/Projects/ford/IPMA/Research
python3 work/patch_thresholds_f1ft.py --selftest            # 17 checks
python3 work/patch_thresholds_f1ft.py --lka-arm 40 --lca-arm 45 --dry-run
python3 work/patch_thresholds_f1ft.py --lka-arm 40 --lca-arm 45 \
        -o F1FT-14F398-AG_LKA40_LCA45.VBF

T=~/.hermes/skills/software-development/vbf-firmware-container/scripts/vbftool.py
python3 $T verify F1FT-14F398-AG_LKA40_LCA45.VBF
python3 $T diff   OEM/F1FT-14F398-AG.VBF F1FT-14F398-AG_LKA40_LCA45.VBF
```

The `40/45` build's diff is **fully accounted**: value-edit bytes across 35
float sites (22 LKA arm = 11×A `+0x080` + 11×B `+0x334`, 11 LCA `+0x598`, 2 m/s)
+ 12 region-hash words (12×4 bytes) + the header file_checksum and block CRC-16
outside the block = **105 changed bytes, zero unexplained**.
`+0x18` verified identical (`0x340BC6D9`).

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
