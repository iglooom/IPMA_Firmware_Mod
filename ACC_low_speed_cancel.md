# ACC low-speed cancellation — bus evidence for the PCM firmware search

**Purpose.** Pin down *which module* ends adaptive cruise control at low speed, *at what
speed*, and *with which signals*, so the threshold can be found in the **PCM/ECM**
firmware later (`/home/gl/Projects/ford/PCM/`). Everything here is decoded from one
drive capture; nothing is inferred from documentation.

Vehicle: Ford C520 EU MY17, VIN `WF0AXXWPMAEL32600`, manual gearbox.
Capture: `hscan_lka_lca_drive2.log` (HS-CAN / `can0`, 2089.6 s) + `mscan_lka_lca_drive2.log`.
Decoded against `/home/gl/Projects/ford/CANBus/CAN-HS.dbc`.
Tooling: `work/drive/` (`dbc.py`, `extract.py`, `build.py`) — see `work/drive/README.md`.
All times below are seconds from the first frame of the HS capture
(`t0 = 1791031023.068`).

---

## 1. Result

| question | answer | evidence |
|---|---|---|
| who ends ACC | **the ECM/PCM**, always | `CcMde_D_Actl` → *Not active* then `CcStat_D_Actl` → *Standby*, both ECM frames, lead every other change |
| low-speed cancel speed | **≈ 22.4 km/h** (22.69 and 22.40 km/h over ground; ECM's own `Veh_V_ActlEng` read 22.61 and 22.18 at the same instant) | 2 events, §4 |
| pre-announce | `AccEngStat_D_Actl` → *"ACC will soon be cancelled due to low speed"* only **30–58 ms** before the drop — same control cycle, **not** an earlier warning threshold | §4 |
| does the radar cancel | **no.** `AccDeny_B_Rq` never asserted in 35 min; `AccCancl_B_Rq` rises **4–224 s after** the ECM already quit | §3 |
| radar's own low-speed latch | `AccCancl_B_Rq` 0→1 at **10.6 – 12.2 km/h** (13 edges, mean 11.5) — a *different* threshold in a *different* module (CCM) | §3 |
| brake release | ABS drops `AccBrkActv_B_Actl` **48–50 ms after** the ECM state change | §4 |

**Threshold candidates to look for in the PCM binary** (22.4–22.6 km/h bracket):

| value | encoding | note |
|---|---|---|
| **6.25 m/s** | `0x40C80000` f32, `0x40C8` f16-ish, or fixed point | 22.50 km/h exactly; 6.25 is binary-clean (25/4) — strongest candidate |
| **22.5 km/h** | `2250` in 0.01 km/h (`0x08CA`), `225` in 0.1 km/h (`0x00E1`), `5760` in 1/256 km/h | matches the CAN resolution the ECM already uses (`Veh_V_ActlEng` = 0.01 km/h) |
| **14 mph** | `14`, or `22.531` km/h | 14 mph = 22.53 km/h, inside the measured bracket; Ford calibrations do carry mph constants |
| **22.0 / 23.0 km/h** | `2200` / `2300` | cannot be excluded with n = 2 |

A companion **re-engage / minimum-set** constant almost certainly sits next to it — not
measured here (the only resume in this drive was at 46 km/h, `CcMde_D_Actl` =
*Resuming Low*). Expect a hysteresis pair, as in the IPMA speed gates.

---

## 2. Signal inventory

Everything used below, with the bit position needed to re-decode or to match against
firmware CAN handlers. `byte.bit` is 1-based byte, bit counted **from the MSB**
(Ford CSV convention); `start|len@order` is the DBC convention.

| signal | frame | sender | start\|len@ord | byte.bit | scale / offset | unit |
|---|---|---|---|---|---|---|
| `CcStat_D_Actl` | `1A0` ECM_h_FrP08 | ECM | 10\|3@m | 2.5 | x1 | enum |
| `CcMde_D_Actl` | `200` ECM_h_FrP09 | ECM | 51\|3@m | 7.4 | x1 | enum |
| `AccEngStat_D_Actl` | `280` ECM_h_FrP11 | ECM | 5\|3@m | 1.2 | x1 | enum |
| `Veh_V_ActlEng` | `130` ECM_h_FrP07 | ECM | 55\|16@m | 7.0 | x0.01 | km/h |
| `BpedDrvAppl_D_Actl` | `138` ECM_h_FrP14 | ECM | 19\|2@m | 3.4 | x1 | enum |
| `EngAout_N_Actl` | `090` ECM_h_FrP03 | ECM | 36\|13@m | 5.3 | x2 | rpm |
| `AccMsgTxt_D_Rq` | `040` CCM_h_FrP00 | CCM | 59\|4@m | 8.4 | x1 | enum |
| `AccWarn_D_Dsply` | `040` CCM_h_FrP00 | CCM | 46\|2@m | 6.1 | x1 | enum |
| `AccFllwMde_B_Dsply` | `040` CCM_h_FrP00 | CCM | 39\|1@m | 5.0 | x1 | enum |
| `AccTrgDist_D_Dsply` | `040` CCM_h_FrP00 | CCM | 27\|4@m | 4.4 | x1 | 16 bars |
| `AccTGap_D_Dsply` | `040` CCM_h_FrP00 | CCM | 36\|3@m | 5.3 | x1 | enum |
| `AccBrkTot_A_Rq` | `1A8` CCM_h_FrP01 | CCM | 52\|13@m | 7.3 | x0.0039 −20 | m/s² |
| `AccCancl_B_Rq` | `1A8` CCM_h_FrP01 | CCM | 8\|1@m | 2.7 | x1 | enum |
| `AccDeny_B_Rq` | `1A8` CCM_h_FrP01 | CCM | 10\|1@m | 2.5 | x1 | enum |
| `AccTrgDist2_D_Dsply` | `1A8` CCM_h_FrP01 | CCM | 3\|4@m | 1.4 | x1 | enum |
| `AccVeh_V_Trg` | `250` CCM_h_FrP02 | CCM | 32\|9@m | 5.7 | x0.5 | km/h |
| `AccPrpl_A_Rq` | `250` CCM_h_FrP02 | CCM | 17\|10@m | 3.6 | x0.01 −5 | m/s² |
| `AccBrkActv_B_Actl` | `2D0` ABS_h_FrP08 | ABS | 55\|1@m | 7.0 | x1 | enum |
| `StopLamp_B_RqBrk` | `2D0` ABS_h_FrP08 | ABS | 50\|1@m | 7.5 | x1 | enum |
| `BpedMove_D_Actl` | `2D0` ABS_h_FrP08 | ABS | 39\|2@m | 5.0 | x1 | enum |
| `VehOverGnd_V_Est` | `160` ABS_h_FrP00 | ABS | 23\|16@m | 3.0 | x0.01 | km/h |
| `VehLongOvrGnd_A_Est` | `160` ABS_h_FrP00 | ABS | 1\|10@m | 1.6 | x0.035 −17.9 | m/s² |
| `Veh_V_ActlBrk` | `1E0` ABS_h_FrP04 | ABS | 39\|16@m | 5.0 | x0.01 | km/h |
| `CcButtnStat_D_Actl` | `030` BCM_h_FrP00 | BCM | 34\|11@m | 5.5 | x1 | bitfield |
| `AccEnbl_B_RqDrv` | `150` BCM_h_FrP02 | BCM | 22\|1@m | 3.1 | x1 | enum |
| `AccDeny_B_RqIpc` | `310` BCM_h_FrP04 | BCM | 0\|1@m | 1.7 | x1 | enum |
| `AccDeny_B_RqMntr` | `310` BCM_h_FrP04 | BCM | 8\|1@m | 2.7 | x1 | enum |
| `GearPos_D_Actl` | `0D0` TCM_h_FrP01 | TCM | 15\|4@m | 2.0 | x1 | enum |

Enumerations that matter:

- `CcStat_D_Actl`: 0 Off, 1 Denied, 2 Standby Denied, **3 Standby**, 4 Active Que Assist, **5 Active**
- `CcMde_D_Actl`: **0 Not active**, **1 KeepingSpeed**, 2 Accelerating, 3 Decelerating, 4 Resuming High, 5 Resuming Low, 6 TapUpWaiting, 7 TapDownWaiting
- `AccEngStat_D_Actl`: **0 Normal Operation**, 1 ACC in standby due to automatic cancel, 2 ACC not allowed to be activated, 3 Shift-up rec., 4 Shift-down rec., **5 ACC will soon be cancelled due to low speed**
- `AccMsgTxt_D_Rq`: 0 No_Text, 1 ACC_Unavailable, **2 ACC_Cancelled**, 3 Brake_Capacity_Warning, 4 ACC_Overridden, 9 Only_Following_in_Low_Spd, 10 Press_Brake_to_Hold …
- `AccWarn_D_Dsply`: 0 No Warning, **1 Cancel Warning**, 2 Brake Capacity Warning, 3 Brake Release Warning in Stop Mode
- `BpedMove_D_Actl`: **0 Autonomous Brake Pedal Movement**, 1 none, **2 Driver is Applying Brake Pedal**, 3 Unknown
- `BpedDrvAppl_D_Actl`: 0 not allowed, **1 driver not braking**, **2 driver braking**, 3 not allowed
- `AccTrgDist2_D_Dsply`: 0 DIST_OFF, 1 DIST_STANDBY, 2 DIST_ACTIVE_No_Target, 3…15 DIST_ACTIVE_1_Closest … 13_Farthest

---

## 3. All ten ACC disengagements in the capture

`CcStat_D_Actl` 5 (*Active*) → other, with the first signal that moved before it:

| # | t [s] | v [km/h] | trigger | first evidence | lead |
|---|---|---|---|---|---|
| 1 | 134.95 | 119.69 | driver brake | ECM `BpedDrvAppl` → *driver braking* | −100 ms |
| 2 | 244.95 | 104.85 | driver brake | ECM `BpedDrvAppl` | −81 ms |
| 3 | 746.80 | 47.58 | cruise button | BCM `CcButtnStat_D_Actl` = 8 | −99 ms |
| 4 | 804.06 | 45.67 | driver brake | ECM `BpedDrvAppl` | −100 ms |
| 5 | 859.20 | 33.42 | driver brake | ECM `BpedDrvAppl` | −102 ms |
| 6 | 899.56 | 45.32 | driver brake | ECM `BpedDrvAppl` | −81 ms |
| 7 | 975.76 | 46.01 | driver brake | ECM `BpedDrvAppl` | −60 ms |
| **8** | **1123.71** | **22.69** | **low speed** | ECM `AccEngStat` → *SoonCancel-LowSpd* | **−30 ms** |
| 9 | 1990.32 | 72.73 | driver brake | ECM `BpedDrvAppl` | −61 ms |
| **10** | **2018.08** | **22.40** | **low speed** | ECM `AccEngStat` → *SoonCancel-LowSpd* | **−58 ms** |

In **every** case `CcMde_D_Actl` → *Not active* precedes `CcStat_D_Actl` → *Standby* by
50–60 ms. The CCM contributes nothing before the fact:

```
AccDeny_B_Rq   : 0 edges in the whole capture
AccCancl_B_Rq  : 13 rising edges, ALL at 10.6–12.2 km/h, +4.0 s … +224 s after the ECM quit
AccDeny_B_RqIpc / AccDeny_B_RqMntr (BCM): constant 0
```

---

## 4. The two low-speed events, full timeline

Sampled at 0.2 s; `AccBrkRq` = `AccBrkTot_A_Rq`, `bars` = `AccTrgDist_D_Dsply`,
`pedal` = `BpedMove_D_Actl`.

### 4.1 Event 8 — t = 1123.70 s, cancel at 22.69 km/h

```
  dt[s]   v km/h  a_long  AccBrkRq  vTrg  bars  CcStat   CcMde      AccEngStat         ACC brk  lamp  pedal        gear  rpm
 -11.85    46.24   -0.01     -0.03  43.0    12  Active   KeepSpd    Normal                -      -   -               4  1834
  -8.84    46.16   -0.01     -0.06  34.5    10  Active   KeepSpd    Normal                -      -   -               4  1822
  -8.44    45.97   -0.08     -0.30  34.0     9  Active   KeepSpd    Normal             BRAKING   -   -               4  1756   CCM starts braking
  -7.43    44.52   -0.29     -0.41  33.5     8  Active   KeepSpd    Normal             BRAKING   -   -               4  1754
  -6.43    41.71   -1.27     -1.01  31.0     8  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       4  1642   lamp + autonomous pedal
  -6.03    39.43   -1.87     -1.63  29.0     7  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       4  1554   peak -1.9 m/s^2
  -5.02    34.37   -0.89     -0.75  29.5     7  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       4  1350
  -4.02    31.46   -1.38     -1.02  26.0     7  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       4  1232
  -3.62    29.80   -1.06     -1.03  26.0     7  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       4  1112   passes 30 km/h, NO cancel
  -2.54    27.36   -0.19     -0.29  25.0     7  Active   KeepSpd    Normal             BRAKING   -   -               3  1430   driver downshift 4->3
  -1.60    26.72   -0.29     -0.49  23.5     6  Active   KeepSpd    Normal             BRAKING   -   -               3  1262
  -0.60    24.45   -1.27     -0.74  21.5     6  Active   KeepSpd    Normal             BRAKING   -   -               3  1222
  -0.40    24.08   -0.89     -0.87  20.5     6  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       3  1174
  -0.20    23.43   -0.68     -0.93  20.0     6  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       3  1138
  +0.00    22.69   -1.06     -0.98  19.5     6  Standby  NotActive  SoonCancel-LowSpd  BRAKING  LAMP  ACC-brake       3  1158  <<< CANCEL
  +0.20    21.75   -0.89     -0.91  18.5     6  Standby  NotActive  NotAllowed            -     LAMP  ACC-brake       3  1094   ABS drops ACC braking
  +1.00    19.69   -0.40     -0.53  16.0     6  Standby  NotActive  Normal                -     LAMP  ACC-brake       3  1040
  +1.41    19.11   -0.40     -0.20  16.0     5  Standby  NotActive  Normal                -      -   -               3  1020   lamp off, coasting
  +2.82    18.36   -0.08     -0.19  11.0     3  Standby  NotActive  Normal                -      -   -               3   974   gap still closing
  +3.02    17.63   -1.27     -0.56   9.5     3  Standby  NotActive  Normal                -      -   DRIVER-brake    3   966   driver takes over
  +3.82    12.36   -1.87     -2.03   5.5     1  Standby  NotActive  Normal                -      -   DRIVER-brake    3   832
```

```
 -8.591  ABS/CCM  AccBrkActv_B_Actl   -> Active
 -6.590  ABS      StopLamp_B_RqBrk    -> Active ; BpedMove -> Autonomous Brake Pedal Movement
 -4.790  ABS      BpedMove            -> none          (brake modulated)
 -4.031  ABS      BpedMove            -> Autonomous
 -2.990  ABS      StopLamp            -> Inactive
 -2.749  ABS      AccBrkActv          -> Inactive
 -2.548  ABS      AccBrkActv          -> Active
 -2.542  TCM      GearPos_D_Actl      fourth -> third              (driver downshift)
 -0.431  ABS      StopLamp -> Active ; BpedMove -> Autonomous
 -0.051  ECM      CcMde_D_Actl        KeepingSpeed -> Not active   <<< first bus evidence
 -0.030  ECM      AccEngStat_D_Actl   Normal -> ACC will soon be cancelled (low speed)
 +0.000  ECM      CcStat_D_Actl       Active -> Standby            <<< 22.69 km/h
 +0.002  ECM      AccEngStat_D_Actl   -> ACC not allowed to be activated
 +0.050  ABS      AccBrkActv_B_Actl   Active -> Inactive           (braking withdrawn)
 +0.101  CCM      AccMsgTxt_D_Rq      No_Text -> ACC_Cancelled
 +0.101  CCM      AccWarn_D_Dsply     No Warning -> Cancel Warning
 +0.210  ECM      AccEngStat_D_Actl   -> Normal Operation
 +0.602  CCM      AccFllwMde_B_Dsply  Active -> Inactive
 +1.089  ABS      BpedMove            Autonomous -> none
 +1.329  ABS      StopLamp            Active -> Inactive
 +2.879  ECM      BpedDrvAppl_D_Actl  not braking -> DRIVER BRAKING
 +3.082  CCM      AccWarn_D_Dsply     Cancel Warning -> No Warning   (warning lasts 3.0 s)
```

### 4.2 Event 10 — t = 2018.08 s, cancel at 22.40 km/h (hard brake from 62 km/h)

```
  dt[s]   v km/h  a_long  AccBrkRq  vTrg  bars  CcStat   CcMde      AccEngStat         ACC brk  lamp  pedal        gear  rpm
 -11.80    61.89   -0.01     -0.02  60.5     0  Active   KeepSpd    Normal                -      -   -               6  1278
  -6.17    62.19   -0.01     -0.02  41.0    13  Active   KeepSpd    Normal                -      -   -               6  1270   target acquired
  -5.97    62.22   -0.01     -0.12  40.0    13  Active   KeepSpd    Normal             BRAKING   -   -               6  1274   CCM starts braking
  -5.39    62.28   -0.01     -0.85  35.5    12  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       6  1270
  -4.56    60.12   -1.38     -1.64  29.0    11  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       6  1218
  -3.76    54.18   -2.46     -3.50  27.0    10  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       6  1170   peak request -3.5
  -3.16    48.55   -2.04     -2.40  28.0     9  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       5  1348   driver 6->5
  -2.15    41.50   -1.48     -1.98  25.0     8  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       5  1154
  -1.14    32.61   -3.02     -2.97  18.5     8  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       5   924   peak actual -3.0
  -0.94    30.16   -3.02     -2.80  18.5     8  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       5   952   passes 30 km/h, NO cancel
  -0.72    28.00   -3.02     -2.57  19.0     8  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       4   942   driver 5->4
  -0.14    23.09   -2.36     -1.59  19.0     8  Active   KeepSpd    Normal             BRAKING  LAMP  ACC-brake       4   770
  +0.00    22.40   -1.66     -1.44  19.0     8  Standby  NotActive  SoonCancel-LowSpd  BRAKING  LAMP  ACC-brake       4   754  <<< CANCEL
  +0.20    21.02   -1.66     -1.87  19.5     8  Standby  NotActive  NotAllowed            -     LAMP  ACC-brake       4   734   ABS drops ACC braking
  +0.80    18.20   -1.06     -1.15  17.5     9  Standby  NotActive  Normal                -     LAMP  ACC-brake       3   726
  +1.61    16.93   -0.08     -0.26  17.5    10  Standby  NotActive  Normal                -      -   -               3   738   lamp off
  +2.01    17.20   +0.16     +0.11  17.5    10  Standby  NotActive  Normal                -      -   -               3   742   driver pulls away
  +3.82    18.80   +0.16     +0.18  15.0     9  Standby  NotActive  Normal                -      -   -               3   720
```

```
 -7.990 / -5.990  ABS   AccBrkActv_B_Actl  -> Active (brief, then sustained)
 -5.390           ABS   StopLamp -> Active ; BpedMove -> Autonomous Brake Pedal Movement
 -3.162 / -0.722  TCM   GearPos  6->5, 5->4                     (driver downshifts)
 -0.059           ECM   CcMde_D_Actl       KeepingSpeed -> Not active   <<< first bus evidence
 -0.058           ECM   AccEngStat_D_Actl  Normal -> ACC will soon be cancelled (low speed)
 +0.000           ECM   CcStat_D_Actl      Active -> Standby            <<< 22.40 km/h
 +0.001           ECM   AccEngStat_D_Actl  -> ACC not allowed to be activated
 +0.020           CCM   AccMsgTxt -> ACC_Cancelled ; AccWarn -> Cancel Warning
 +0.048           ABS   AccBrkActv_B_Actl  Active -> Inactive
 +0.209           ECM   AccEngStat_D_Actl  -> Normal Operation
 +0.520           CCM   AccFllwMde_B_Dsply Active -> Inactive
 +0.778           TCM   GearPos  4->3
 +1.530           ABS   BpedMove -> none
 +1.651           ABS   StopLamp -> Inactive
 +3.000           CCM   AccWarn -> No Warning
```

### 4.3 Speed sources at the cancel instant

| source | event 8 (last 3 samples before) | event 10 |
|---|---|---|
| `VehOverGnd_V_Est` (ABS `160`) | 22.66, 22.69, **22.69** | 22.88, 22.42, **22.40** |
| `Veh_V_ActlBrk` (ABS `1E0`) | 22.57, 22.62, **22.46** | 22.52, 22.19, **22.10** |
| `Veh_V_ActlEng` (ECM `130`) | 22.56, 22.56, **22.61** | 22.51, 22.51, **22.18** |
| `Veh_V_ActlTrn` (TCM `2B0`) | 0.00 (not transmitted on this car) | 0.00 |

The ECM publishes its own speed on `130`; the crossing bracket on **that** value is
**22.18 … 22.61 km/h**, i.e. the firmware comparison sits on ~22.4 ± 0.25 km/h of
whatever internal speed feeds `Veh_V_ActlEng`.

---

## 5. What this does and does not establish

**Established from the capture**

- The PCM/ECM owns the decision: its two frames (`200`, `1A0`) move first in all 10 events.
- The low-speed drop-out is **≈ 22.4 km/h**, not 30 km/h: the car passed 30 km/h while
  still *Active* and still ACC-braking in both events (see the marked rows at −3.62 s and
  −0.94 s).
- The CCM's `AccCancl_B_Rq` is a *consequence* with its own, lower threshold (~11.5 km/h).
- ACC braking is released 48–50 ms after the state change, with the gap still closing —
  the driver gets the car back mid-deceleration.
- The cluster "ACC cancelled" text + cancel warning come from the **CCM** (`040`), 20–100 ms
  after the ECM state change, and last 3.0 s.

**Not established**

- The exact constant: two samples give a 22.18–22.69 km/h bracket, nothing finer.
- Whether the comparison uses the ECM's own wheel-derived speed, the ABS value from `160`,
  or a filtered internal signal.
- Whether `AccEngStat_D_Actl` = 5 has its own (slightly higher) threshold — in both events
  it appeared in the same control cycle as the cancel, so it cannot be separated here.
- The re-engage / minimum-set speed, and whether a hysteresis pair exists.

**The control that would settle it** — two or three in-gear coast-downs with ACC active,
no brake, no clutch, on a flat road, decelerating gently (< 0.5 m/s²) so the 20 ms speed
quantum is worth < 0.03 km/h; log `can0` only. Ten clean crossings pin the threshold to
±0.05 km/h, the same way the IPMA LKA/LCA gates were pinned
(`IPMA_speed_gates.md`). Pair it with a slow acceleration from standstill with ACC armed
to capture the re-engage speed.

---

## 6. Reproducing these numbers

```bash
cd /home/gl/Projects/ford/IPMA/Research/work/drive
python3 extract.py ../../hscan_lka_lca_drive2.log ../../mscan_lka_lca_drive2.log drive2.json
python3 build.py drive2.json ../../drive2_dashboard.html      # interactive page, panel "ACC — state"
```

The dashboard's *Adaptive cruise control* panels show both events directly; the event
times above are its x-axis times. Ad-hoc timeline extraction is a short script against
`work/drive/dbc.py` (`dbc.load_dbc()`, `dbc.iter_log(path, {ids})`, `dbc.extract(...)`) —
see §4 for the signal set.

---

## 7. Hand-off to the PCM work

> **RESOLVED** — see `/home/gl/Projects/ford/PCM/PCM_Research/ACC_LOW_SPEED_GATE.md`.
> The gate is a plain window `25.0 <= v <= 200.0` in the generated cruise model step
> (`0x802B70C0–0x802B7192`, latched in `0xD000797C`, master permit `0xD000794F`), with
> the constant at **`0x8015A108` = `25.0`**. The comparison runs on the PCM's internal
> *speedometer-corrected* speed `0xD000A25C`, built from raw speed through a 5-point map
> (`0/40/100/130/260 → 0/43.8/104.55/136/272.7`, slope **1.095** below 40 km/h), so
> 25.0 internal = **22.83 km/h over ground** — matching the 22.40 / 22.69 measured here
> to within 1–3 of the model's 50 ms steps. The `AccEngStat = 5` pre-announce is a
> separate 25/26 hysteresis (`0x8015A0FC` / `0x8015A100`) evaluated in the same step,
> which is why its lead was only 30–58 ms. Re-engage floor is the minimum *set* speed,
> 30.0 internal = 27.40 km/h true. Candidate "6.25 m/s / 22.5 km/h / 14 mph" of §1: all
> wrong — the real constant is a round 25 in corrected units.

The firmware side lives in `/home/gl/Projects/ford/PCM/`. What to look for:

1. The handler that builds frame `1A0` (`CcStat_D_Actl`, 3 bits at byte 2 bit 5 MSB-first)
   and frame `200` (`CcMde_D_Actl`, byte 7 bit 4) — these are the outputs whose transition
   is timed above; the comparison that drives them is upstream.
2. A speed comparison against one of the constants in §1 feeding both that state machine
   and the `AccEngStat_D_Actl` = 5 flag (frame `280`, byte 1 bit 2) — the two are set in the
   same cycle, so they likely read the same compare result.
3. The driver-brake path (`BpedDrvAppl_D_Actl`, frame `138`) and the cruise-button path
   (`CcButtnStat_D_Actl` from BCM `030`) enter the same state machine — useful as
   cross-references to locate it, since those are the other 8 cancels.
4. Expect the constant in the **calibration** area rather than code, as with the IPMA
   speed gates; if the PCM is MED17-family, the integrity layers documented in
   `PCM_Research`/`AGENTS.md` apply before any modification.
