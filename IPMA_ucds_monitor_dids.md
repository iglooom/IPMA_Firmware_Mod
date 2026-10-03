# IPMA — UCDS "Monitor" DID set (49 pages), decoded

Companion to [IPMA_ucds_direct_config.md](IPMA_ucds_direct_config.md) (the
*Configuration* screen). This one covers the **Monitor / Read Data** screen:
49 list entries, each exactly one UDS DID at 0x706 (resp 0x70E).

Source: `ucds_ipma_read_dids.log` (candump, can0), UCDS → IPMA → `Read All`,
C520 EU MY17, IPMA F1FT rel 4.93.06 **with the LKA40/LCA45/HOLD12 calibration
already flashed**.

Decoder: `work/decode_ipma_dids.py <candump.log>` — reassembles ISO-TP and
prints the table below; it handles both logs.

---

## 1. Protocol

Plain `22 <DID>` reads, 8-byte padded ISO-TP, flow control `30 00 00`.
**No session change and no SecurityAccess** — the whole monitor set is readable
in default session (unlike the Direct Configuration DIDs, which need
`10 03` + `27 03/04`). `Read All` walks the list top to bottom, so the read
order in the log *is* the on-screen order; that is what pins the names below.

Two pages answer `7F 22 31` (requestOutOfRange) and show nothing:
`F162` (#8 Software Download Specification Version) and `FD0C`
(#48 FBL Boot Software Version Number).

## 2. The 49 pages

| # | UCDS label | DID | len | raw | decoded |
|---|---|---|---|---|---|
| 1 | Number of Trouble Codes Set due to Diagnostic Test | `0202` | 1 | `00` | 0 DTCs |
| 2 | Active Diagnostic Session | `D100` | 1 | `01` | default |
| 3 | Boot Software Version Number | `F109` | 3 | `04 04 08` | v4.4.8 |
| 4 | On-line Diagnostic Database Reference Number | `F110` | 24 | ASCII | `DS-F1FT-19H406-AE` |
| 5 | ECU Core Assembly Number | `F111` | 24 | ASCII | `F1FT-14F403-AE` |
| 6 | ECU Delivery Assembly Number | `F113` | 24 | ASCII | `F1FT-19H406-AH` |
| 7 | NOS Generation Tool Version Number | `F15F` | 10 | `08 06 00 00 81 01 15 02 00 00` | — |
| 8 | Software Download Specification Version | `F162` | — | `7F 22 31` | not readable |
| 9 | Diagnostic Specification Version | `F163` | 1 | `03` | 3 |
| 10 | NOS Message Database #1 Version Number | `F166` | 4 | `11 05 06 00` | — |
| 11 | Vehicle Manufacturer ECU Software Number | `F188` | 24 | ASCII | `F1FT-14F397-AG` (application) |
| 12 | Internal Failure Codes | `FD24` | 40 | u16[20], 0-terminated | 18 codes, see §4 |
| 13 | ECU States | `FD23` | 16 | all zero | — |
| 14 | **Software Checksum** | `FD22` | 12 | 3 × u32 BE | `0CBC60C1 / A785BD89 / A6A09E1D` — see §3 |
| 15 | Intrinsic Sensor Tolerances | `FD21` | 6 | 3 × int16 BE | 1249, −83, 368 |
| 16 | Front Heated Windshield Activation Statistics | `41B5` | 10 | u32,u32,u16 | 7629, 540, 48 |
| 17 | Framework Usage Statistics | `FD1D` | 4 | u32 | 0 |
| 18 | TSR Usage Statistics | `FD1C` | 4 | u32 | 16 |
| 19 | DAS Usage Statistics | `FD1B` | 8 | 2 × u32 | 383, 0 |
| 20 | AHBC Usage Statistics | `FD1A` | 12 | 3 × u32 | 123732, 1513, 1550 |
| 21 | LCA Usage Statistics | `FD19` | 8 | 2 × u32 | 18, 1 |
| 22 | LDW Usage Statistics | `FD17` | 12 | 3 × u32 | 243, 99, 77 |
| 23 | LKA Usage Statistics | `FD18` | 12 | 3 × u32 | 4799, 2092, 3717 |
| 24–26 | CAN signal matrix group 1 / 2 / 3 | `FD1E` `FD1F` `FD20` | 20 each | all zero | — |
| 27 | Wheel House Heights | `41BA` | 8 | 4 × u16 BE (mm) | FL 742, FR 748, RL 790, RR 795 |
| 28 | Camera Alignment Status | `41BB` | 2 | `00 00` | aligned / no fault |
| 29 | Calibration Environmental Data | `FD16` | 21 | see §5 | counter 145213 + the `41BA` heights |
| 30 | **APAR Wheel House Heights** | `FD15` | 8 | 4 × u16 BE (mm) | **FL 745, FR 745, RL 756, RR 756** — matches the screenshot exactly |
| 31 | Continental Internal Software Part Number | `FD13` | 3 | `04 5D 06` | — |
| 32 | Continental Internal Hardware Part Number | `FD14` | 3 | `09 27 00` | — |
| 33 | Heater Usage Statistics | `FD0A` | 8 | 2 × u32 | 0, 0 |
| 34 | LA Switch Status | `FD09` | 1 | `00` | lane-assist switch off |
| 35 | Reflash Limit Monitoring | `FD11` | 4 | `00 04 00 5F` | 4 reflashes done / 95 allowed (see §6) |
| 36 | Calibration Status | `FD0F` | 2 | `01 00` | calibrated |
| 37 | Window Heater Status | `FD0E` | 1 | `00` | off |
| 38 | Window Heater Availability | `FD0D` | 1 | `01` | fitted |
| 39 | Camera Parameters | `FD0B` | 8 | 4 × int16 BE | −242, −242, 70, −528 |
| 40 | LDW Usage Data | `FD04` | 12 | 3 × u32 | 0, 0, 0 |
| 41 | TSR Usage Data | `FD03` | 12 | 3 × u32 | 0, 0, 0 |
| 42 | AHBC Usage Data | `FD02` | 12 | 3 × u32 | 162468, 2336, 0 |
| 43 | Internal Temperature | `FD01` | 8 | 2 × u32, 0.1 °C | **21.0 °C / 21.6 °C** |
| 44 | Temperature Histogram | `FD00` | 50 | 25 × u16 BE | see §7 |
| 45 | ECU Serial Number | `F18C` | 16 | ASCII | `90000216226000BA` |
| 46 | ECU Calibration Data #1 Number | `F124` | 24 | ASCII | `F1FT-14F398-AG` (parameter part) |
| 47 | ECU Software #2 Part Number | `F120` | 24 | ASCII | `F1FT-14F397-BE` (DSP part) |
| 48 | FBL Boot Software Version Number | `FD0C` | — | `7F 22 31` | not readable |
| 49 | Boot Software Identification | `F180` | 25 | `01` + ASCII | v1 `F1FT-14F400-AD` (PBL) |

The four part-number DIDs together describe the whole flash set:
PBL `14F400-AD` (`F180`), application `14F397-AG` (`F188`), DSP `14F397-BE`
(`F120`), calibration `14F398-AG` (`F124`) — exactly the parts in `OEM/`.

---

## 3. FD22 "Software Checksum" — a live fingerprint of what is flashed

Three big-endian u32, one per flashed part, in part order:

| word | value | identified as | source of truth |
|---|---|---|---|
| 0 | `0x0CBC60C1` | **BootNfo CRC-32 of `F1FT-14F397-AG`** (application) | recomputed from `OEM/F1FT-14F397-AG.VBF`, exact match |
| 1 | `0xA785BD89` | **`BootNfo +0x1C` metadata digest of `F1FT-14F398-AG_LKA40_LCA45_HOLD12`** (patched calibration) | `IPMA_LKA_hold_time.md` §"Built artifact", `F1FT_speed_gates.md` |
| 2 | `0xA6A09E1D` | **crc32 of the compressed DSP payload of `F1FT-14F397-BE`** | `IPMA_dsp_application.md` table, `work/dsp/unwrap_dsp.py` |

Three independently derived constants, from three different documents, all
reproduced by one 12-byte DID. Two consequences:

- **FD22 is the live proof of what is running.** `F124` still reports the OEM
  part number `F1FT-14F398-AG` after flashing a patched calibration (the patch
  keeps the part number); FD22 word 1 does not. `0xA785BD89` is the HOLD12
  build — not OEM (`0xBFEB7F98`) and not the gates-only build
  (`0xE2CA9AB1`). Read this DID to confirm a flash landed, with no VBF needed.
- It confirms the module keeps a self-computed digest per block, consistent
  with the `U2101` behaviour analysed in `F1FT_speed_gates.md`: the stale
  `+0x1C` digest is what the module compares.

## 4. FD24 "Internal Failure Codes"

20 × u16 BE, zero-terminated list; 18 entries present:

```
9C30 9C31 3004 9C34 9C35 1E1C 9C16 1446 3005
9C64 9C65 9C67 9C68 9C6A 9C60 9C62 3009 0C02
```

These are Continental-internal codes, not UDS DTCs (no status byte, no 3-byte
form). Clustering is obvious — `9C3x`, `9C6x`, `30xx` — so the high byte is a
subsystem and the low byte a cause. Not decoded further; the module reports
**0 DTCs** (`0202` = 0) at the same time, so this list is informational
history, not active faults.

## 5. FD15 / 41BA / FD16 — ride-height trio

- `FD15` **APAR Wheel House Heights** = 4 × u16 BE millimetres,
  order **FL, FR, RL, RR** — proven: the screenshot shows 745/745/756/756 and
  the bytes are `02E9 02E9 02F4 02F4`. APAR = the aiming/alignment reference
  set (symmetric left/right, i.e. nominal design values for the variant).
- `41BA` **Wheel House Heights** = same layout, the *measured* set:
  742/748/790/795 — asymmetric, as a real vehicle is, and 34–39 mm higher at
  the rear than the APAR reference.
- `FD16` **Calibration Environmental Data** = 21 bytes:
  8 zero bytes, a 3-byte counter `0x02373D` = **145213** (odometer in km at the
  last calibration is the obvious reading — unconfirmed), then the four
  `41BA` heights verbatim, then 2 zero bytes. It is a snapshot of the vehicle
  state when the camera was last aligned.

These feed the static alignment in `FD05` (Direct Configuration): camera
height 1442 mm, longitudinal 778 mm, lateral −5 mm.

## 6. FD11 "Reflash Limit Monitoring"

`00 04 00 5F` — read as two u16 BE: **4** and **95**. Four flash cycles have
been performed on this module (which matches the flashing history in
`FLASH_RESULTS.md`), against a ceiling of 95. Worth re-reading after each
flash: if word 0 increments by one per download, it is a hard counter and the
module has a finite number of writes left.

## 7. FD00 "Temperature Histogram"

25 × u16 BE bins, 50 bytes, no header:

```
bin   0   1   2    3    4     5     6      7      8      9     10    11
      0   0   0   73  370  1857  3615  16267  23172  20098  7110  5813
bin  12  13   14   15    16   17  18  19  20..24
    5200 4115 3167 2294 1094  267  20   3   0
```

Total 94535 samples. A clean unimodal distribution peaking at bin 8 with a long
hot tail — exactly what a lifetime operating-temperature histogram looks like.
Bin width/offset are not established by this capture; with the module reading
21.0 °C (`FD01`) and the peak at bin 8, a −40 °C base with 5 °C bins
(peak ≈ 0–5 °C ambient-soaked) and a 10 °C-bin variant both remain possible.
To settle it, read `FD00` twice across a long temperature excursion and watch
which bins increment.

## 8. Usage counters — what they say about this car

| system | DID | counters |
|---|---|---|
| LKA | `FD18` | 4799 / 2092 / 3717 |
| LDW | `FD17` | 243 / 99 / 77 |
| LCA | `FD19` | 18 / 1 |
| AHBC | `FD1A` | 123732 / 1513 / 1550 (+ `FD02` 162468 / 2336 / 0) |
| TSR | `FD1C` | 16 (`FD03` usage data all zero) |
| DAS | `FD1B` | 383 / 0 |

The LKA ≫ LDW ordering is the expected one for this vehicle's configuration
(lane *aid* enabled, lane *warning* mode rarely selected) and is consistent
with the post-patch 40 km/h activation threshold producing many more
interventions. **Caveat:** the LDW/LKA assignment rests on `Read All`
following list order (`FD19`, then `FD17`, then `FD18` on the wire against list
entries 21/22/23). Everything else in the list maps 1:1 under that assumption,
including seven DIDs whose names are fixed independently by ISO 14229 or by
their ASCII content, so the assumption is well supported — but if one pair in
this table is worth re-checking by selecting a single page on screen, it is
`FD17` vs `FD18`.

## 9. Relation to the rest of the research

Nothing in the monitor set is writable, so it changes no conclusion about the
speed gates. Its value is operational:

- `FD22` — verify a flash landed, and which build, from the car (§3).
- `FD11` — remaining flash cycles (§6).
- `FD18`/`FD19` — count LKA/LCA interventions before and after a patch, an
  independent odometer-free check that the lowered gates are being used.
- `41BB` + `FD0F` + `FD15`/`41BA`/`FD16` — camera alignment health, the things
  to check before touching `FD05`.
