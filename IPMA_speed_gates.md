# IPMA speed gates — located, decoded, modified, validated

The headline result: **LKA, LDW and LCA activation speeds live in the IPMA
calibration part, are encoded as `[arm, band]` pairs in km/h, and were
successfully changed and validated on the road to within 0.1 km/h.**

---

## 1. The IPMA is the gate — not the PSCM

Measured on an instrumented drive (`drive1`, 141 097 samples, stock firmware):

```
PSCM allows lane assist from   39.39 km/h     LaActAvail_D_Actl -> 3
IPMA first commands LKA at     61.64 km/h
IPMA first shows  LCA at       74.85 km/h
```

The PSCM declares availability **22 km/h before** the camera acts. It is
permissive, not restrictive.

> **A correction this overturned.** Stationary testing showed
> `LaActAvail_D_Actl = 0` with the real camera working, which looked like a
> PSCM speed gate and cast doubt on whether IPMA work was worthwhile. It was
> not a gate — the PSCM simply mirrors the camera's state. Only a moving
> vehicle could distinguish the two.

### Per-feature flags are what actually gate

`LaActAvail_D_Actl` is a **combined** enum (`3 = "LKA/LCA and LDW available"`)
and by construction cannot separate the features. The IPMA publishes
**per-feature** flags on `0x1B5`, each defined *"Vehicle is in operating speed
range"*:

| feature | signal | stock enter | stock leave |
|---|---|---|---|
| **LKA** | `LkaVLvl_B_Dsply` | **64.56** km/h (n=9) | **59.44** (n=9) |
| **LDW** | `LdwVLvl_B_Dsply` | **64.56** km/h (n=9) | **59.44** (n=9) |
| **LCA** | `LcaVLvl_B_Dsply` | **80.01** km/h (n=2) | **75.03** (n=2) |

**LDW shares LKA's gate exactly** — identical sample counts and speeds. LCA has
its own.

---

## 2. The encoding — `[arm @ +0x000, band @ +0x010]`, km/h

Both features use one scheme, and **the drop-out is computed as `arm − band`,
not stored**:

| table | rec | arm | band | `arm − band` | measured (stock) |
|---|---|---|---|---|---|
| `0x30A01048` / `0x30A01058` | **2** | **64.60** | **5.00** | **59.60** | LKA **64.56 / 59.44** |
| `0x30A01068` | all 4 | **80.00** | **5.00** | **75.00** | LCA **80.01 / 75.03** |

LCA deltas of **+0.01 / +0.03 km/h** — inside the CAN signal's own resolution.

This is why an exhaustive search for a stored 75 km/h or 20.83 m/s constant
returns **empty**: there is no disengage constant to find. Recognising that
turned a long-running failure into the answer.

Sanity check on the other records, all consistent:

| rec | arm | band | drop | m/s copy ×3.6 |
|---|---|---|---|---|
| 0 | 59.60 | 5.00 | **54.60** | **54.60** ← exact |
| 1 | 59.60 | 4.30 | 55.30 | 55.44 |
| **2** | **64.60** | **5.00** | **59.60** | 60.01 |
| 3 | 60.60 | 5.00 | 55.60 | 55.80 |

### Addresses (variant record 2 — the one this vehicle runs)

```
LKA arm    mem 0x06AE0  (tag 0x30A01048 rec2 +0x000)  64.6 km/h
LKA band   mem 0x06AF0  (tag 0x30A01048 rec2 +0x010)   5.0 km/h
LKA arm    mem 0x05DE4  (tag 0x30A01058 rec2 +0x000)  64.6 km/h   duplicate
LKA band   mem 0x05DF4  (tag 0x30A01058 rec2 +0x010)   5.0 km/h   duplicate

LCA arm    mem 0x06348/0x063D4/0x06460/0x064EC  (tag 0x30A01068 +0x000)  80.0
LCA band   mem 0x06358/0x063E4/0x06470/0x064FC  (tag 0x30A01068 +0x010)   5.0

LKA m/s    mem 0x05458 (arm, 17.94) / 0x05454 (drop, 16.67)
           (tag 0x30A01038 rec2 +0x1C4 / +0x1C0)  — NOT operative, see §4
```

---

## 3. How it was found

The values are not unique in the block — `40.0` appears 18 times and `50.0`
15 times in 17 KB. Single-value matching is worthless here. What worked:

1. **Hysteresis as a signature.** The driver recalled *"LKA engages at 65 and
   cancels around 60"*. A matched on/off pair must satisfy ordering, ratio and
   proximity simultaneously. An exhaustive sweep of every adjacent float pair
   in 5–45 m/s with `on > off` and a 1–8 km/h gap returned 19 candidates —
   **only one** landed on 60/65. A single value could never have done this.
2. **Cross-unit agreement.** Three independent tables encode the same
   per-record series, and the m/s table converts to the km/h tables **exactly**
   (×3.6, 4/4 records) across three different strides. Coincidence cannot
   survive that.
3. **Per-feature separation.** Asking *"does the PSCM enable LKA or LCA?"*
   forced attention onto `LcaVLvl_B_Dsply`, which exposed the `[arm, band]`
   encoding and located the LCA gate that single-value scanning had missed.
4. **Cross-version corroboration** (see §5).
5. **Road validation** (see §6).

### Refuted hypotheses — recorded so they are not retried

* **"The thresholds are in mph."** 65/80 km/h ≈ 40/50 mph looked compelling.
  **Refuted**: the gain-schedule axis decodes to exactly 60/70/80/90/100/113/
  130/150 km/h. Units are m/s and km/h.
* **"Record A = LKA, record B = LCA."** Refuted: `0x33A8`/`0x33D8` are
  different fields straddling a record boundary. Records are per-*variant*.
* **"`[59.6, 59.6, 64.6, 60.6]` is a vehicle dimension in inches."** Refuted by
  the exact ×3.6 match to the m/s table — they are speeds.
* **"The km/h tables are mirrors of the m/s pair."** Refuted: they are
  `[arm, band]`, a different and more informative structure.
* **"LKA interventions are capped by a ~3.7 s timer."** Refuted: durations
  ranged 0.18–3.72 s, all 10 ended in the *speed-gate* state (7), and several
  re-triggered within seconds. Duration tracks road curvature, as the driver
  reported.

---

## 4. Which copy is operative — ANSWERED by the road test

Before the drive this was genuinely open: the located code at `0x0C13FC` reads
offsets `+0x1C0`/`+0x1C4` (the **m/s** offsets) but from a RAM base
(`ld24 r8,0x82dc6c`), so it could not be attributed to a flash table with
confidence. All copies were therefore patched consistently.

`drive3` settles it — **the km/h `[arm, band]` pairs are operative**:

```
LKA  arm 40.0  band 5.0  ->  predicted drop 35.0   measured 34.91
LCA  arm 45.0  band 5.0  ->  predicted drop 40.0   measured 39.94
```

Decisive: tag `0x30A01068` (LCA) has **no m/s counterpart**, so the LCA result
could only have come from the km/h encoding.

### The hysteresis gate in code

```
c13fc:  a0 c8 01 c0   ld r0,@(448,r8)      <- +0x1C0
c1400:  d2 00 02 00   *unknown*            <- FPU compare
c1404:  60 02 f0 00   ldi r0,#2
c1408:  a1 c8 01 4c   ld r1,@(332,r8)      <- state variable
c140c:  b1 10 00 03   bne r1,r0,0xc1418
c1410:  a0 c8 01 c4   ld r0,@(452,r8)      <- +0x1C4
c1414:  d2 00 02 40   *unknown*            <- same FPU op, other condition
```

Textbook two-threshold hysteresis: a state variable selects which threshold to
compare against. The two FPU words differ by a single nibble.

**Still open:** the RAM base `r8` (from `@(80,sp)`) was not traced back to the
tag resolver, and binutils cannot decode the FPU opcodes. So the *code* proof
is incomplete even though the *behavioural* proof is conclusive.

---

## 5. Cross-version corroboration

| | CV4T 4.27.0 | BM5T 4.5.5 | F1FT 4.93.06 |
|---|---|---|---|
| load address | `0x003000` | `0x003000` | `0x902000` |
| region index / tag table | yes, file `0x008C` | yes, identical | **restructured, none** |
| tag `0x30A01038` records | **4** | **2** | 9 rows, compact table |
| 16.67 / 17.94 m/s pair | **rec 2** | **absent** | **row 2**, standalone |

* CV4T and BM5T records 0 and 1 are **byte-identical over 0x408 bytes**.
* BM5T lacks the high-threshold variant entirely — consistent with a
  lower-spec Transit.
* F1FT physically restructured the container (different load address, no tag
  table, stride `0x408` → `0x3F8`), and the quadruple
  `[16.670, 17.940, 68.0, 70.0]` **survived intact at the same index 2**.

A coincidence does not survive a container rewrite.

---

## 6. The modification, and its road validation

Patched with `work/patch_thresholds.py`, flashed, then measured on `drive3`
(233 356 samples, 0–56.4 km/h):

| feature | OEM | target | **measured** | error |
|---|---|---|---|---|
| **LKA** engage | 64.56 | 40.0 | **40.04** (n=26) | **+0.04** |
| **LKA** drop | 59.44 | 35.0 | **34.91** (n=26) | **−0.09** |
| **LCA** engage | 80.01 | 45.0 | **45.09** (n=13) | **+0.09** |
| **LCA** drop | 75.03 | 40.0 | **39.94** (n=13) | **−0.06** |
| **LDW** | 64.56/59.44 | — | **40.04 / 34.91** | tracks LKA |

**Every edge within 0.1 km/h of target across 78 transitions.**

Real interventions followed: 5 LKA interventions at 43.7–52.9 km/h (below the
OEM 64.6 gate) and 20 LCA activations from 41.2 km/h.

> **CORRECTION — the earlier torque claim was wrong.** This document previously
> stated *"peak steering torque during intervention 3.02 Nm"* as evidence the
> modification is gentle. `TorsionBarTorque` (0x140) is **driver input torque**,
> not EPS assist output: a torsion-bar sensor sits between the wheel and the
> rack while the assist motor acts below it. Measured proof — hands-off mean
> **0.108 Nm** vs hands-on **0.784 Nm**, a 7.3× ratio tracking driver presence.
> **There is no EPS assist-torque signal on this bus at all**, so the actual
> steering authority applied at the lowered thresholds was never measured and
> remains unquantified from CAN.
>
> The *threshold* measurements are unaffected — those come from the
> `LkaVLvl_B_Dsply` / `LcaVLvl_B_Dsply` flags, not from torque.

The PSCM was unaffected: `LaActAvail` allowed from 39.39 km/h, identical to
stock, with `LaActDeny = 0` throughout.

---

## 7. Reproducing this

```bash
# locate candidate thresholds by hysteresis signature
python3 work/scan_hysteresis.py bins/CV4T-14F398-AF_blk0_0x00003000.bin

# patch (dry run first)
python3 work/patch_thresholds.py --lka-arm 40 --lca-arm 45 --dry-run
python3 work/patch_thresholds.py --lka-arm 40 --lca-arm 45 -o OUT.VBF

# measure on the road
python3 ../../PSCM/Research/work/vehicle/la_monitor.py --iface can0 --log driveN
python3 ../../PSCM/Research/work/vehicle/analyse_drive.py driveN.jsonl
```

Watch `LkaVLvl_B_Dsply` and `LcaVLvl_B_Dsply` — those are the gate flags.

---

## 8. Safety note

LKA now engages in a speed range Ford never validated: tighter urban corners,
more parked-car and junction clutter than a 65 km/h design point assumes. The
gain schedule *predicts* lower authority at these speeds, and the system
remains fully overridable — but the applied authority was **never measured**
(no EPS assist-torque signal exists on this bus, see §6), so treat this as an
evaluation configuration, not routine assistance.

Reverting is a single flash of the untouched `CV4T-14F398-AF.VBF`.
