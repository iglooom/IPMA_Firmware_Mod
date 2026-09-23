# Ford IPMA research

Reverse engineering of the Ford IPMA (Image Processing Module A) forward
camera, with the goal of lowering the LKA / LCA activation speed thresholds so
the systems can be exercised without highway access.

**Result: achieved and validated on the road.** LKA moved from 64.6 to 40.0
km/h and LCA from 80.0 to 45.0 km/h, every threshold landing within 0.1 km/h of
target across 78 measured transitions.

Vehicle: Ford C520 EU MY17, VIN `WF0AXXWPMAEL32600`, IPMA release 4.27.0.

---

## Documents

| Document | Contents |
|---|---|
| **[IPMA_speed_gates.md](IPMA_speed_gates.md)** | **The main result.** Where the thresholds live, the `[arm, band]` encoding, how they were found, what was refuted, the modification and its road validation. |
| **[IPMA_LKA_hold_time.md](IPMA_LKA_hold_time.md)** | **The ~3.7 s LKA intervention cap** — located at `tag58 +0x178` (seconds), the marshaller/countdown chain in the app, the 65.535 s u16 ceiling, and how to patch it. |
| **[F1FT_speed_gates.md](F1FT_speed_gates.md)** | **The F1FT (4.93.06 / CSF2F0) patch.** Restructured flat 28-row index, the solved per-region `~crc32` integrity layer, where the LKA/LCA fields moved, and the still-open `+0x18` top word (left unchanged, believed download-tool-only). |
| [IPMA_module.md](IPMA_module.md) | Processor (Renesas M32R / M32192), firmware set, memory map, BootNfo integrity descriptor, building the M32R toolchain. |
| [IPMA_calibration_format.md](IPMA_calibration_format.md) | The self-describing calibration container: region index, element-size table, per-variant records, tag-based access, known field semantics. |
| [IPMA_flashing.md](IPMA_flashing.md) | SecurityAccess secret and how it was recovered, the real OEM flash sequence, integrity repair order, recovery posture. |
| [CROSS_VERSION.md](CROSS_VERSION.md) | Detailed comparison across three OEM firmware generations (CV4T 4.27.0, BM5T 4.5.5, F1FT 4.93.06). |
| [IPMA_config_and_flash_risk.md](IPMA_config_and_flash_risk.md) | Why the As-Built / UDS configuration route does **not** work (clean negative), and the original risk assessment. |
| [EXE_integrity_monitor.md](EXE_integrity_monitor.md) | The **application (EXE)** four-layer integrity recipe — incl. the internal CRC-32C at `end-7` — and the runtime monitor that enforces it. |
| [FLASH_RESULTS.md](FLASH_RESULTS.md) | Session log: secret recovery, wire-level flash verification, drive3 validation. |

Superseded briefing documents kept for provenance: `BRIEF.md`,
`DISASM_BRIEF.md`, `FINDINGS.md`. Where they conflict with the four documents
above, **the documents above are correct** — the briefs contain hypotheses that
were later refuted (notably "the thresholds are in mph" and "M32R has no FPU").

---

## The result in one table

| feature | OEM | modified | measured on road | error |
|---|---|---|---|---|
| **LKA** engage | 64.56 km/h | 40.0 | **40.04** (n=26) | +0.04 |
| **LKA** drop | 59.44 km/h | 35.0 | **34.91** (n=26) | −0.09 |
| **LCA** engage | 80.01 km/h | 45.0 | **45.09** (n=13) | +0.09 |
| **LCA** drop | 75.03 km/h | 40.0 | **39.94** (n=13) | −0.06 |
| **LDW** | tracks LKA | — | **40.04 / 34.91** | — |

Steering authority at the lowered thresholds is **not quantified**: the only
torque signal on the bus (`TorsionBarTorque`) measures *driver input*, not EPS
assist output — see the correction in `IPMA_speed_gates.md` §6.

---

## Key facts

```
Processor        Renesas M32R (M32192), big-endian, WITH hardware FPU
Platform         Continental CSF2xx
Diagnostic IDs   0x706 request / 0x70E response
SecurityAccess   secret 0x00009875CA  (level 1)
Calibration      CV4T-14F398-AF, 17448 B, loads 0x00003000, big-endian float32
Threshold form   [arm @ +0x000, band @ +0x010] in km/h; drop = arm - band
Live variant     record 2 of 4
Integrity        BootNfo CRC-32 -> block CRC-16 -> file CRC-32  (in that order)
```

---

## Tools

Under `work/` (stdlib Python 3 only, no venv required):

| Tool | Purpose | Self-tests |
|---|---|---|
| `patch_thresholds.py` | Edit the CV4T speed thresholds **and the LKA hold time**, repair all three integrity layers | 40+ |
| `patch_thresholds_f1ft.py` | Edit the F1FT thresholds, repair per-region `~crc32` + container CRCs | 17 |
| `patch_exe_integrity.py` | Re-seal a modified **application (EXE)** — all four layers, incl. the internal CRC-32C | 13 |
| `ipma_flash.py` | Flash a VBF over UDS; replays both captures as tests | 20 |
| `ford_seckey_solve.py` | Recover a SecurityAccess secret from captured pairs | 15 |
| `scan_hysteresis.py` | Locate thresholds by activate/deactivate signature | 5 |
| `scan_float_speeds.py` | Float32 speed-constant scan, both endiannesses | — |
| `find_ld24.py` | Find M32R `LD24` instructions loading a given address | 5 |
| `build/binutils/objdump` | M32R disassembler, built from binutils 2.42 | — |

On the PSCM side, `../../PSCM/Research/work/vehicle/`:

| Tool | Purpose |
|---|---|
| `la_monitor.py` | Live lane-assist monitor + logger (CSV/JSONL/candump) |
| `analyse_drive.py` | Derive thresholds and the binding gate from a drive log |
| `precondition_check.py` | Ask the PSCM whether lane assist is available |

---

## Typical workflow

```bash
# 1. inspect and extract
T=~/.hermes/skills/software-development/vbf-firmware-container/scripts/vbftool.py
python3 $T info CV4T-14F398-AF.VBF
python3 $T verify *.VBF
python3 $T extract CV4T-14F398-AF.VBF -o bins/

# 2. patch (dry run first)
python3 work/patch_thresholds.py --lka-arm 40 --lca-arm 45 --dry-run
python3 work/patch_thresholds.py --lka-arm 40 --lca-arm 45 -o OUT.VBF
python3 $T verify OUT.VBF && python3 $T diff CV4T-14F398-AF.VBF OUT.VBF

# 3. flash
python3 work/ipma_flash.py --vbf OUT.VBF --sbl CV4T-14F399-AF.VBF --dry-run

# 4. validate on the road
python3 ../../PSCM/Research/work/vehicle/la_monitor.py --iface can0 --log driveN
python3 ../../PSCM/Research/work/vehicle/analyse_drive.py driveN.jsonl
```

---

## What made this work

Static analysis alone would not have succeeded. `40.0` appears 18 times and
`50.0` 15 times in a 17 KB block — any single value match is worthless.

The decisive inputs were **on-vehicle measurements**:

* the driver's recollection of *hysteresis* (65 on, 60 off) turned an
  ambiguous scan into a unique hit;
* asking whether the PSCM gates **LKA or LCA separately** exposed the
  per-feature flags, which revealed the `[arm, band]` encoding and located the
  LCA gate;
* an instrumented drive proved the IPMA — not the PSCM — is the binding gate,
  overturning an earlier stationary reading;
* the final drive resolved which stored copy the firmware actually reads,
  something no amount of static analysis had settled.

Several confident intermediate conclusions were **wrong and later retracted**
(mph units, per-feature records, "no FPU"). They are documented in
`IPMA_speed_gates.md` §3 so they are not retried.

One *retraction* was itself wrong: the "3.7 s intervention timer" was dismissed
on single-drive evidence, then found in the calibration after all
(`tag58 +0x178`, seconds). See [`IPMA_LKA_hold_time.md`](IPMA_LKA_hold_time.md).

---

## Verifying the documentation

Documentation drifts. `work/verify_docs.py` re-derives every load-bearing
number in these documents from the actual binaries, captures and drive logs:

```bash
python3 work/verify_docs.py       # -> DOC VERIFICATION: ALL CLAIMS CONFIRMED
```

It checks 40+ claims: the BootNfo layout and CRCs, the region index and every
record stride, the `[arm, band]` values at their stated addresses, the absence
of a stored disengage constant, the SecurityAccess secret against both captured
sessions, that the flashed bytes match our VBFs, the drive3 thresholds, and
that every tool still passes its own self-tests.

It has already earned its keep: it caught two wrong claims in the first draft
of `IPMA_module.md` (the calibration block tags itself `CSF265`, not `CSF2*`,
and `M32192` lives in the **SBL**, not the calibration part).

Run it after editing any document or tool.

---

## Open questions

* **What selects the variant record at runtime.** Nothing in the calibration
  encodes a selector; it must be application-side, plausibly a configuration
  DID.
* **Code-level proof of the threshold read.** The hysteresis gate at `0x0C13FC`
  reads the right offsets but from a RAM base that was not traced back to the
  tag resolver, and binutils cannot decode the M32R FPU opcodes. The
  behavioural proof is conclusive; the code proof is not complete.
* **The F1FT BootNfo `+0x18` top word** is unreproduced by any standard CRC.
  It is left unchanged in the F1FT patch (which only edits per-region-hashed
  regions, never the metadata it covers) and appears to be an OEM download-tool
  word not read at runtime — but this must be confirmed on the bench before the
  F1FT part is relied upon. See `F1FT_speed_gates.md` §4.
* **Region tag `0x00000A00`** (`0x012C`..`0x1A84`, the largest) has no chunk
  entry and was never decomposed.

---

## Safety

LKA now engages in a speed range Ford never validated: tighter corners, more
urban clutter than a 65 km/h design point assumes. Measured authority is
*lower* at these speeds (the gain schedule ramps from zero) and the system
remains fully overridable — but this is an **evaluation configuration**, not
routine assistance.

Reverting is a single flash of the untouched `CV4T-14F398-AF.VBF`.
