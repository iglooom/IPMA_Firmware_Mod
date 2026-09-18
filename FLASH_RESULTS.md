# IPMA flashing — solved

## SecurityAccess secret: `0x00009875CA`

Recovered from two captured OEM flash sessions, then **cross-validated**:

| session | seed | key |
|---|---|---|
| `candump-stock-flash.log` | `3450FC` | `2B3A70` |
| `candump-mod-flash.log` | `50E4BE` | `41C1BA` |

```
secret from STOCK session only : 0x00009875ca
secret from MOD   session only : 0x00009875ca      identical
stock-derived -> predicts MOD pair   : seed 50E4BE expected 41C1BA got 41C1BA  MATCH
mod-derived   -> predicts STOCK pair : seed 3450FC expected 2B3A70 got 2B3A70  MATCH
```

Solving on one session and correctly predicting the *other* session's key is
the real proof — a fit to a single pair could be coincidence; a correct
prediction on an unseen seed cannot.

Method: the keygen is **affine over GF(2)**, so
`key(seed,secret) = A·seed ⊕ B·secret ⊕ c` and one pair determines the secret
class by Gaussian elimination. 16 free bits ⇒ 65 536 equivalent secrets, all
producing identical keys; any member works. Tool:
`work/ford_seckey_solve.py` (15 self-tests, includes re-deriving the
hardware-verified BCM secret as a positive control).

Known Ford secrets now:

```
BCM  0x726 : 0x64000B0C59   verified on hardware
PSCM 0x730 : 0x00009B2533   published, unverified
IPMA 0x706 : 0x00009875CA   SOLVED + cross-validated
```

## The patched flash landed correctly — proven from the wire

The `0x36` transferData payloads were reassembled from both captures and
compared against our files:

```
candump-stock-flash.log : 17448 B -> IDENTICAL to CV4T-14F398-AF.VBF
candump-mod-flash.log   : 17448 B -> IDENTICAL to CV4T-14F398-AF_LKA40_LCA45.VBF
```

Byte-for-byte. The module received exactly the bytes we built, with all three
integrity layers intact (BootNfo CRC-32 → block CRC-16 → file CRC-32).

## Four corrections to `ipma_flash.py`, all from ground truth

My flasher was written from the BCM analogue and was **wrong in four places**.
Each would have failed or degraded a real flash:

1. **Identity DID.** I read `F124` for a DATA part. The OEM tool reads
   **`F113` + `F188`** — and `F188` returns the *application* part
   (`CV4T-14F397-AF`), which never equals a calibration VBF's own part number
   (`CV4T-14F398-AF`). My equality check would have **refused every legitimate
   calibration flash**. Now reports identity and only sanity-checks the
   application family.

2. **SBL start routine.** I used `31 01 FF01 <32-bit address>`. The real
   sequence is **`31 01 0301 0082`** — routine `0301` with the *high half* of
   the call address.

3. **Missing finalise step.** The OEM tool runs **`31 01 0304`** after the
   download and before the reset (reply `71 01 03 04 10 02`). I omitted it
   entirely, leaving the part written but unvalidated.

4. **Block size.** I hardcoded `0x402`. The ECU declares **`74 20 0F FF`** =
   4095, i.e. **4093** payload bytes per `36`. Now parsed from the `0x74`
   response; hardcoding smaller is ~4× slower, larger earns NRC `0x73`.

Observed flash time: **~16 s** for the 17 KB calibration part.

`--secret` now defaults to the solved value, so the tool is usable directly.
20 self-tests pass, including replaying both captures.

## VALIDATED ON THE ROAD — drive3

233 356 samples, 0 … 56.4 km/h, modified calibration.

| feature | OEM | **patched target** | **measured** | error |
|---|---|---|---|---|
| **LKA** engage | 64.56 | 40.0 | **40.04** (n=26) | **+0.04** |
| **LKA** drop | 59.44 | 35.0 | **34.91** (n=26) | **−0.09** |
| **LCA** engage | 80.01 | 45.0 | **45.09** (n=13) | **+0.09** |
| **LCA** drop | 75.03 | 40.0 | **39.94** (n=13) | **−0.06** |
| **LDW** | tracks LKA | — | **40.04 / 34.91** | — |

Every edge within **0.1 km/h** of target, across 78 transitions. Enter values
cluster `39.7 … 40.1`, leave `34.1 … 34.9`.

**The modification works exactly as designed.**

### Which copy is operative — ANSWERED

All copies were patched consistently because it was unproven which one the
firmware reads. The drive settles it: the **km/h `[arm, band]` pairs are
operative**, and they are self-consistent —

```
LKA  arm 40.0  band 5.0  ->  drop 35.0   measured 34.91
LCA  arm 45.0  band 5.0  ->  drop 40.0   measured 39.94
```

The drop-out follows `arm − band` in both features. Had the m/s pair been the
live copy the LCA result could not have worked, since tag68 has no m/s
counterpart.

### Real interventions occurred

5 LKA interventions at **43.7 … 52.9 km/h** — well below the OEM 64.6 gate —
and 20 LCA state-6 transitions from 41.2 km/h upward. All ended in state 7
(the speed gate), consistent with drive1 and with the driver's observation that
duration tracks road curvature, not a timer.

~~Torque during interventions: max 3.02 Nm~~ — **RETRACTED.**
`TorsionBarTorque` is *driver input* torque, not EPS assist output (hands-off
mean 0.108 Nm vs hands-on 0.784 Nm, a 7.3x ratio). No EPS assist-torque signal
exists on this bus, so the applied steering authority is **unmeasured**. The
gain schedule still predicts lower authority at lower speed (its X axis starts
at 0 m/s with gain 0), but that is a prediction, not a measurement.

### PSCM unchanged, as expected

`LaActAvail` allowed from **39.39 km/h** — identical to the stock drive, and
`LaActDeny = 0` throughout. The PSCM was never the gate; lowering the IPMA
threshold did not disturb it.

---

## Status of the modification

Flashed, accepted, and **validated on the road** (see above). The values are:

```
LKA  engage 40.0 km/h   drop 35.0 km/h    (OEM 64.6 / 59.6)
LCA  engage 45.0 km/h   drop 40.0 km/h    (OEM 80.0 / 75.0)
```

Confirmed by `drive3` at 40.04/34.91 and 45.09/39.94 — within 0.1 km/h.

## Undo

Re-flash the untouched `CV4T-14F398-AF.VBF`. Its erase region
(`0x3000`, len `0x4428`) is isolated and never touches the bootloader.
