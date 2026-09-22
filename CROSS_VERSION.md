# Cross-version validation of the IPMA LKA speed gate

Three independent OEM IPMA calibration parts, read-only, via
`vbftool.py {info,verify,extract}`. Working dir
`/home/gl/Projects/ford/IPMA/Research/work/xver/`.

| | CV4T-14F398-AF | F1FT-14F398-AG | BM5T-14F398-AG |
|---|---|---|---|
| release | 4.27.0 | 4.93.06 | 4.5.5 |
| description | IPMA Release 4.27.0 Application Parameters | Release for 4.93.06 Application parameters AH release | IPMA Release 4.5.5 Application Parameters |
| VBF size / blk0 len | 18564 B / 0x4428 | 26744 B / 0x640D | 16499 B / 0x3C18 |
| load address | `0x00003000` | `0x00902000` | `0x00003000` |
| `vbftool verify` | OK | OK | OK |
| ecu_address | 0x706 | 0x706 | 0x706 |

All three containers verify clean (block CRC-16 + file CRC-32 + 0 trailing).

---

## 1. Structure

### CV4T and BM5T — identical layout

Both carry the region index at file `0x008C` with **10 rows** of
`[load_addr, size, flags, tag]`, address-chained, and a chained element-size
table `[next, tag, total, chunk]`. Confirmed present and self-consistent in
both.

| tag | CV4T addr / size / chunk / recs | BM5T addr / size / chunk / recs |
|---|---|---|
| `0x00000A00` | `0x00312C` / `0x1958` / — / — | `0x00312C` / `0x1958` / — / — |
| `0x30A01038` | `0x004A84` / `0x1020` / `0x408` / **4** | `0x004A84` / `0x0810` / `0x408` / **2** |
| `0x30A01058` | `0x005AA4` / `0x0680` / `0x1A0` / 4 | `0x005294` / `0x0680` / `0x1A0` / 4 |
| `0x30A01098` | `0x006124` / `0x0024` / `0x0024` / 1 | `0x005914` / `0x0024` / `0x0024` / 1 |
| `0x30A01088` | `0x006148` / `0x0200` / `0x0080` / 4 | `0x005938` / `0x0200` / `0x0080` / 4 |
| `0x30A01068` | `0x006348` / `0x0230` / `0x008C` / 4 | `0x005B38` / `0x0230` / `0x008C` / 4 |
| `0x30A01048` | `0x006578` / `0x0AD0` / `0x02B4` / 4 | `0x005D68` / `0x0AD0` / `0x02B4` / 4 |
| `0x30A01078` | `0x007048` / `0x035C` / `0x035C` / 1 | `0x006838` / `0x035C` / `0x035C` / 1 |
| `0x30A01028` | `0x0073A4` / `0x0008` | `0x006B94` / `0x0008` |
| `0x30A01018` | `0x0073AC` / `0x0010` | `0x006B9C` / `0x0010` |

Element-size table: CV4T at file `0x43A8` (mem `0x0073A8`), BM5T at file
`0x3B98` (mem `0x006B98`). **Same tag set, same order, same strides.**
The only structural difference is `0x30A01038`: **4 records in CV4T, 2 in
BM5T** (`0x1020` vs `0x0810`, same `0x408` chunk). Every other table has the
same record count in both.

### F1FT — restructured, no tag/region index

F1FT does **not** use the tagged region index. At file `0x008C` it has a flat
array of **28 × 12-byte rows** `[offset, flags=0x000C0100, hash]`. The first 11
offsets are spaced exactly `0x624` apart (`0x902E24`, `0x903448`, `0x903A6C`,
… `0x906B8C`) — 11 per-variant blobs — followed by `0x9071B0` and then three
`0x3F8`-spaced records at `0x90750C`/`0x907904`/`0x907CFC`, then a run of
16-byte entries starting `0x9080F4`.

The `hash` column is not a plain `zlib.crc32` of the pointed-to data (checked
16 B and `0x624` B windows — no match), so it is an unidentified digest.

---

## 2. The threshold — found in all three, unchanged

### CV4T, table `0x30A01038`, stride `0x408`, field `+0x1C0`/`+0x1C4`

```
 rec0 @mem 0x004A84: +1C0= 15.167  +1C4= 16.550  +1C8=68.0 +1CC=70.0
 rec1 @mem 0x004E8C: +1C0= 15.400  +1C4= 16.550  +1C8=68.0 +1CC=70.0
 rec2 @mem 0x005294: +1C0= 16.670  +1C4= 17.940  +1C8=68.0 +1CC=70.0   <<<
 rec3 @mem 0x00569C: +1C0= 15.500  +1C4= 16.830  +1C8=68.0 +1CC=70.0
```

### BM5T, same tag, same base `0x004A84`, same stride — but only 2 records

```
 rec0 @mem 0x004A84: +1C0= 15.167  +1C4= 16.550  +1C8=68.0 +1CC=70.0
 rec1 @mem 0x004E8C: +1C0= 15.400  +1C4= 16.550  +1C8=68.0 +1CC=70.0
```

Byte-for-byte comparison of CV4T rec0/rec1 against BM5T rec0/rec1:
**0 differing bytes in each** (`0x408` bytes compared per record). Two
releases four years apart, identical records. **BM5T has no 16.67/17.94 pair
anywhere in the block** — the m/s scan for 17.8–18.1 returns empty. BM5T is a
2-variant calibration that simply does not contain the high-speed variant.

### F1FT — the pair survives, hoisted into its own table

The big `0x408`-records became `0x3F8`-records (3 of them, at `0x9074FC`,
`0x9078F4`, `0x907CEC`), and `+0x1C0`/`+0x1C4` in them now hold `0.060`/`0.100`
— the speed gate was **factored out** into a dedicated 16-byte-row table at
mem `0x9080F4`, each row `[suppress_m/s, arm_m/s, 68.0, 70.0]`:

```
 row0 0x9080F4:  15.167  16.550  68.000  70.000
 row1 0x908104:  15.400  16.550  68.000  70.000
 row2 0x908114:  16.670  17.940  68.000  70.000   <<< identical to CV4T rec2
 row3 0x908124:  15.400  16.830  68.000  70.000
 row4 0x908134:  15.560  16.950  68.000  70.000
 row5..row8:     15.560  16.950  68.000  70.000
```

Row order is the same as CV4T's record order (`15.167/16.55`, `15.40/16.55`,
`16.67/17.94`, `~15.4-15.5/16.83`), and the trailing `68.0`/`70.0` pair is the
same two constants that sit at `+0x1C8`/`+0x1CC` in the CV4T/BM5T records.
So the F1FT 16-byte row is exactly the CV4T record's `+0x1C0..+0x1CF` slice
extracted into a standalone table.

**16.67 / 17.94 appears in position 2 of the variant list in both CV4T (2015-
era part, rel 4.27.0) and F1FT (rel 4.93.06), with identical neighbours in
identical order.** That is not a coincidence.

---

## 3. The km/h "mirrors" are not mirrors — they are `[arm, …, band]`

`+0x000` of tables `0x30A01048` and `0x30A01058`, all records:

| rec | CV4T tag48 | CV4T tag58 | BM5T tag48 | BM5T tag58 |
|---|---|---|---|---|
| 0 | 59.600 | 59.600 | 59.600 | 59.600 |
| 1 | 59.600 | 59.600 | 59.600 | 59.600 |
| 2 | **64.600** | **64.600** | 59.600 | 59.600 |
| 3 | 60.600 | 60.600 | 59.600 | 59.600 |

F1FT keeps this per-variant at `+0x80` of each `0x624` region: e0 = **64.600**,
e1 = 60.600, e2..e10 = 61.000. Same value set, same leading variant.

**New finding:** `+0x010` of those same records is a hysteresis *band*, not a
copy. `arm − band` reproduces the drop-out speed:

```
  CV4T tag48 r2: arm= 64.600  band= 5.00  ->  drop= 59.600 km/h
  CV4T tag48 r0: arm= 59.600  band= 5.00  ->  drop= 54.600 km/h
  CV4T tag48 r1: arm= 59.600  band= 4.30  ->  drop= 55.300 km/h
  CV4T tag48 r3: arm= 60.600  band= 5.00  ->  drop= 55.600 km/h
```

The drive measured suppress at **59.53 km/h**. The km/h pair gives
**59.600 km/h** (Δ = 0.07); the m/s constant 16.67 gives 60.01 (Δ = 0.48).
**The km/h table matches the vehicle better than the m/s pair does.** That
argues the km/h table at tag48/tag58 record 2 is the copy the firmware
actually consults for the suppress edge, and is a concrete answer to the
"which copy does it read" question in the brief — at minimum it ranks the
candidates.

---

## 4. Record structure and variant selection

The 4 records are per-vehicle-variant. Evidence: within `0x30A01038` only a
handful of fields differ between records — `+0x1C0`/`+0x1C4` (the speed gate)
— while `+0x208`/`+0x20C`/`+0x210`/`+0x214` (`0.0/16.7/19.4/22.2`) and
`+0x3D8` (`22.0`) are identical in every record of every generation. Same for
tag48/tag58, where only `+0x000` and `+0x010` move.

Record count varies by generation: **CV4T 4, BM5T 2, F1FT 9 rows** (with 11
per-variant `0x624` regions for the km/h side). Only `0x30A01038` changes
count; tag48/tag58/tag68/tag88 stay at 4 in both CV4T and BM5T. **What selects
the record is still unknown** — nothing in the calibration block encodes a
selector. It must be an application-side index (vehicle-line / market coded via
a configuration DID). This remains open.

---

## 5. LCA candidate — found, and it is table `0x30A01068`

The invariant `22.0` at `+0x3D8` is a dead end: it sits in the run
`0.035, 22.0, 10.0, 3.0, 5.0, 0.7` and is byte-identical in every record of
all three generations (CV4T `0x04E5C/0x05264/0x0566C/0x05A74`, F1FT
`0x9078D4/0x907CCC/0x9080C4`, BM5T `0x04E5C/0x05264`). Likewise the `22.2` at
`+0x214` is an **axis breakpoint**, not a threshold — its neighbours are
`16.7, 19.4, 22.2, 25.0, 27.8, 31.3, 36.1, 41.7, 70.0` (visible in full at
F1FT `0x907EF8`), a monotone speed-breakpoint vector for a lookup curve.
Neither has a hysteresis partner because neither is a threshold.

**The real candidate is `0x30A01068`**, which has the *same shape* as the
proven LKA tables (`+0x000` = arm, `+0x010` = band):

```
  CV4T tag68 r0..r3 @0x006348/63D4/6460/64EC:  80.000  50.000 180.000 110.000   5.000 ...
  BM5T tag68 r0..r3 @0x005B38/5BC4/5C50/5CDC:  80.000  50.000 180.000 110.000   5.000 ...
  F1FT (13 occurrences, e.g. 0x902774, 0x902D98, … 0x907124): 80.000 50.000 180.000 110.000 5.000 ...

  arm = 80.000 km/h ;  band = 5.000 ;  drop = 75.000 km/h
```

The vehicle measures LCA engage ≈ **80 km/h** and disengage ≈ **75 km/h**.
`0x30A01068` record 2 `+0x000` = 80.0 and `+0x010` = 5.0 reproduce both edges
exactly, using the identical `[arm, band]` encoding already proven on the LKA
tables. `0x30A01068` is also the only table carrying `0x00042501` flags in
CV4T (distinct from the `…402` of tag38/48/58), and it is fully invariant
across all three generations and all 11 F1FT variants — consistent with a
non-variant-coded feature gate.

This is a strong candidate, **not** confirmed: it has not been validated by a
drive against a modified value, and no use-site has been located. Note also
that no `20.8 m/s` / `~75 km/h` literal exists anywhere in any of the three
calibration blocks (exhaustive scans of 20.4–21.3 m/s and 73–77 km/h return
empty in CV4T and BM5T; F1FT's single `75.0` at `0x9081A8` is followed by
`97.0, 5.0, 11.11, 8.61` and has no CV4T/BM5T counterpart at all). The absence
of a stored disengage constant is exactly what the `arm − band` scheme
predicts, and is itself corroboration.

---

## 6. BootNfo internal checksum

Descriptor at block offset 0, magic `0xAA5AA555` at `+0x0C`.

```
CV4T: label='A.D.C._CRCst' start=0x00003000 end=0x00007427
      stored CRC @0x24 = 0xCEDEF18D   calc (zlib.crc32, 4 bytes at 0x24 SKIPPED) = 0xCEDEF18D   MATCH
BM5T: label='A.D.C._CRCst' start=0x00003000 end=0x00006C17
      stored CRC @0x24 = 0x2F9A9B6A   calc (same algorithm)                      = 0x2F9A9B6A   MATCH
F1FT: NO 'A.D.C._CRCst' label. Descriptor is 0xC bytes shorter:
      start @0x10 = 0x00902000   end @0x14 = 0x0090840C   CRC @0x18 = 0x340BC6D9
      declared span 0x640C == block length 0x640C (+1 pad)   -> field identification is sound
```

Both CV4T and BM5T verify with the stated algorithm and their declared span is
`len-1` in each case (`0x4427` vs `0x4428`; `0x3C17` vs `0x3C18`).

### UPDATE — F1FT integrity is now solved enough to patch (see `F1FT_speed_gates.md`)

The earlier conclusion "do not patch F1FT" is **superseded**. F1FT uses a
different, two-tier scheme, and the layer that a value edit actually invalidates
is solved:

* **Per-region hash (the operative layer).** The flat 28-row index at block
  `0x8C` stores, per region, `~zlib.crc32(region) & 0xFFFFFFFF` — a standard
  reflected CRC-32 (`0xEDB88320`, init `0xFFFFFFFF`) **without the final
  XOR-out**. Verified reproducing **28/28** stored hashes, confirmed against the
  app's CRC core `0x0A8B50` and the runtime validator `0x15D94`. This is
  recomputable, so any edited region's hash can be repaired.
* **`+0x18 = 0x340BC6D9` top word — still not reproduced** by any standard
  CRC-32/CRC-32C over any contiguous span (exhaustive C sweeps, all-poly, GF(2)
  init-solving; see `work/f1ft/crack*.c`). But it is **left unchanged** and
  believed safe because every threshold edit lands inside a per-region-hashed
  region, never in the metadata `[0..0xE24)` that `+0x18` covers, and no runtime
  read of `+0x18` was found (it appears to be an OEM download-tool word). Must be
  confirmed on the bench.

**Practical consequence:** both CV4T and F1FT parts are now patchable. The F1FT
patch tool is `work/patch_thresholds_f1ft.py`; the built, statically-verified
artifact is `F1FT-14F398-AG_LKA40_LCA45.VBF`.

---

## Verdict

**Cross-version evidence substantially strengthens the identification.**

1. `16.67 / 17.94` m/s is present in **two independent releases four years
   apart** (CV4T 4.27.0 and F1FT 4.93.06), at the **same position (index 2) in
   the same ordered variant list**, with the **same neighbouring rows** and the
   **same trailing constants** (`68.0`, `70.0`). F1FT physically restructured
   the calibration — different load address, different index format, no tag
   table, records re-strided `0x408`→`0x3F8` — and the speed-gate quadruple
   survived intact as a standalone table. A coincidence would not survive a
   container rewrite.
2. CV4T and BM5T records 0 and 1 are **byte-identical** (`0x408` bytes, 0
   differences each), proving the field layout is stable across the family and
   that the `+0x1C0/+0x1C4` offsets are not an artefact of one build.
3. BM5T lacks the pair entirely and is a 2-variant calibration — consistent
   with a lower-spec Transit that does not offer the high-threshold variant,
   and further evidence that the records are vehicle-variant rows.
4. The km/h tables were **mis-read as mirrors**. They are `[arm, …, band]`
   with `arm − band = drop`, and they reproduce the measured suppress
   (59.53 km/h) as 59.600 — closer than the m/s constant's 60.01. This is a
   correction to the brief.
5. The same `[arm, band]` encoding in `0x30A01068` yields **80.0 / 75.0 km/h**,
   matching the measured LCA engage/disengage exactly. Promising LCA candidate,
   invariant across all three generations, **unconfirmed**.

Still open: the runtime record selector, the use-site instruction, and the
F1FT BootNfo CRC algorithm.
