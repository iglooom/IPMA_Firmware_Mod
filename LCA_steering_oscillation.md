# LCA lane-centering oscillation — measurement and evidence

**Observation being tested.** While LCA is centering the car, the steering visibly
hunts left–right. Reported as more pronounced in the `drive1` capture.

**Verdict.** Confirmed and quantified: a periodic weave at **0.19–0.25 Hz (4–5 s
period)** on a straight road, in which the camera's angle request **leads** the car's
yaw response. Felt severity scales with speed, which is why `drive1` (117–120 km/h) is
worse than `drive2` (56 km/h median) even though the steering amplitudes are similar.
What is *not* established is a controller-vs-road attribution by positive control — see
§6.

Vehicle: Ford C520 EU MY17, VIN `WF0AXXWPMAEL32600`, IPMA with the lowered LKA/LCA
speed gates. Captures: `hscan_lka_lca_drive1.log` (18.0 min) and
`hscan_lka_lca_drive2.log` (34.8 min), HS-CAN `can0`, decoded against
`/home/gl/Projects/ford/CANBus/CAN-HS.dbc`.
Tooling: `work/drive/analyze_osc.py` (analysis), `work/drive/extract.py` +
`build.py` (10 Hz bundle + dashboards). Times are seconds from the first frame of each
HS capture.

---

## 1. Signals used

| signal | frame | sender | meaning here |
|---|---|---|---|
| `LkaActvStats_D_Req` | `0A5` IPMA_h_FrP01 | IPMA | state 6 = *LCA in progress* — defines the windows |
| `LaRefAng_No_Req` | `0A5` IPMA_h_FrP01 | IPMA | the camera's steering-angle request, mrad (0.05 mrad/bit, −102.4) |
| `LaCurvature_No_Calc` | `0A5` IPMA_h_FrP01 | IPMA | camera road-curvature estimate, 1/m — used to prove the road is straight |
| `SteeringAngle` (+`SteeringAngleSign`) | `010` SASM_h_FrP00 | SASM | actual steering angle, signed, deg |
| `VehYawComp_W_Actl` | `180` ABS_h_FrP01 | ABS | yaw rate, deg/s — the car's response |
| `VehLatComp_A_Actl` | `180` ABS_h_FrP01 | ABS | lateral acceleration, m/s² — what the occupants feel |
| `TorsionBarTorque` (+sign) | `140` PSCM_h_FrP01 | PSCM | driver input torque — confirms the driver is not causing it |
| `LaLLineStats_D_Dsply` / `LaRLineStats_D_Dsply` | `1B5` IPMA_h_FrP02 | IPMA | lane-line tracking state — confirms no line dropouts |
| `VehOverGnd_V_Est` | `160` ABS_h_FrP00 | ABS | speed |

Bit layouts for all of these are in `ACC_low_speed_cancel.md` §2 or directly in
`work/drive/extract.py`'s `SPEC` table.

---

## 2. Method

1. Resample everything to **10 Hz** (`extract.py`; mean per bin for continuous channels).
2. Keep 60 s windows, stepped 20 s, with speed ≥ 35 km/h, classified
   **LCA** when `LkaActvStats_D_Req` = 6 for ≥ 90 % of the window.
3. **De-trend** each channel with a centred **15 s** moving average. This removes road
   curvature and steady cornering while leaving a 4–5 s wobble intact.
   *Pitfall:* a 3 s de-trend window (the first attempt) is a ~0.3 Hz high-pass and
   deletes the very oscillation under test — the de-trend window must be several times
   longer than the period being measured.
4. Dominant frequency by direct DFT over 0.05–1.2 Hz at 0.005 Hz resolution; RMS of the
   de-trended signal; band-limited RMS over **0.15–0.35 Hz** (3–7 s) for drive-to-drive
   comparison.
5. Cross-correlate the de-trended `LaRefAng_No_Req` against the de-trended yaw rate over
   ±3 s; a positive lag means the request leads the response.

Frequencies below ~0.07 Hz are within the de-trend roll-off and are **not** trustworthy;
treat the 0.05–0.11 Hz peaks reported for drive2 as "slow drift", not a measured mode.

---

## 3. Results

### 3.1 Aggregate, LCA windows only

| | drive1 | drive2 |
|---|---|---|
| LCA windows (60 s, ≥35 km/h) | 15 | 51 |
| median speed | 117 km/h | 56 km/h |
| dominant period (median) | **4.7 s (0.215 Hz)** | 9.5 s (0.105 Hz, at the filter edge) |
| steering RMS, de-trended (median / p90) | 0.80° / 1.46° | 0.82° / 1.78° |
| **yaw RMS** | **0.33 °/s** | 0.27 °/s |
| **lateral-accel RMS** | **0.20 m/s²** | 0.11 m/s² |
| steering reversals/min (>0.3°) | 14 | 11 |
| band-limited steering 0.15–0.35 Hz (median / p90 / max) | **1.354° / 2.435° / 2.888°** | 1.108° / 2.382° / 3.077° |

Read this carefully: **by steering amplitude the two drives are comparable**
(1.35° vs 1.11° median in the 3–7 s band). The difference is speed — the same wobble at
120 km/h instead of 60 km/h yields ~2× the yaw and lateral acceleration, which is the
quantity the driver perceives. That is the whole of "more pronounced in drive1".

### 3.2 Worst LCA windows, drive1

```
     t[s]    v    steer°  ref[mrad] yaw°/s  alat  trq[Nm] curv  f[Hz] period  lag[s] corr rev/min
    720.0 119.6    1.47     2.85    0.60   0.37   0.40  0.22  0.215   4.7s  +0.10 +0.87  29.0
    940.0  93.3    1.46     2.82    0.47   0.22   0.47  0.16  0.185   5.4s  +0.70 +0.58  18.0
    700.0 119.6    1.26     2.28    0.52   0.32   0.24  0.19  0.220   4.5s  +0.10 +0.92  24.0
    680.0 119.7    1.03     1.73    0.42   0.25   0.24  0.18  0.220   4.5s  +0.20 +0.90  19.0
    480.0 116.9    1.01     5.40    0.33   0.21   0.32  0.11  0.215   4.7s  +1.60 +0.35  14.0
    920.0 105.8    0.86     1.91    0.33   0.19   0.16  0.17  0.185   5.4s  +0.30 +0.87  17.0
    640.0 119.3    0.81     1.57    0.34   0.22   0.12  0.14  0.245   4.1s  +0.20 +0.91  15.0
    660.0 119.8    0.80     1.65    0.34   0.23   0.12  0.14  0.220   4.5s  +0.20 +0.93  16.0
    620.0 117.5    0.65     1.27    0.27   0.18   0.13  0.12  0.245   4.1s  +0.20 +0.87  12.0
    600.0 116.1    0.59     1.12    0.24   0.16   0.12  0.11  0.245   4.1s  +0.20 +0.85   6.0
```
`curv` = de-trended camera curvature RMS ×10⁻³ 1/m. `lag` = `LaRefAng` → yaw.

### 3.3 Worst LCA windows, drive2 (for contrast)

```
   1620.0  51.8    1.94     3.40    0.57   0.21   0.32  0.62  0.075  13.3s  +0.40 +0.90  11.0
   1820.0  72.8    1.92     3.74    0.73   0.21   0.38  0.57  0.100  10.0s  +0.40 +0.73  10.0
   1840.0  73.0    1.92     3.83    0.70   0.23   0.40  0.51  0.105   9.5s  +0.40 +0.75  10.0
   1600.0  48.8    1.88     3.27    0.54   0.21   0.33  0.59  0.080  12.5s  +0.30 +0.90  11.0
   1740.0  68.2    1.79     3.49    0.66   0.22   0.22  0.51  0.230   4.3s  +0.40 +0.90  13.0
```
Mostly a slow 10–13 s drift with high curvature content (0.5–0.6 ×10⁻³ 1/m — a winding
road being followed), **except** `t = 1740 s`, which is the same 4.3 s mode at 68 km/h.

### 3.4 Excerpt — drive1, t = 700–740 s, ~119.5 km/h (every 0.5 s)

`(detr)` columns are de-trended; state 6 = LCA in progress; lines held `NOT/ovr` throughout.

```
    t[s]   refAng  (detr)  steer°  (detr)  yaw°/s  alat   trq     v
   700.0   -4.72   -3.03   -0.58   -0.84   -0.88  -0.53  -0.08  120.0
   702.0   -1.74   +0.44   -0.12   -0.15   -0.19  -0.32  -0.12  119.9
   704.5   -3.50   -1.10   -0.48   -0.32   -0.70  -0.47  -0.08  120.0
   707.0   -1.62   +1.52    0.00   +0.55   -0.37  -0.44  -0.11  119.9
   709.0   -3.74   -1.05   -0.97   -0.51   -0.84  -0.58  -0.04  119.9
   711.5   -1.20   +1.66    0.14   +0.59   -0.48  -0.29  -0.20  119.8
   714.0   -7.28   -4.86   -2.42   -2.11   -1.34  -0.82  +0.06  119.8
   716.0   +0.98   +3.16   +1.18   +1.47   +0.15  +0.03  -0.20  119.5
   718.0   -4.66   -2.79   -0.76   -0.64   -0.88  -0.53  +0.11  119.3
   720.0   +0.46   +2.06   +0.86   +0.60   -0.05  -0.15  -0.22  118.9
   723.5   -2.22   -2.27   -0.85   -2.52   -0.55  -0.24  -0.74  119.2
   725.5   +0.96   +0.45   +2.68   +0.58   +0.48  +0.28  +0.50  119.3
   728.5   +6.62   +4.99   +6.67   +3.64   +2.38  +1.03  +0.49  119.2
   731.0   +1.10   -1.28   +3.74   -0.03   +1.20  +0.50  +0.05  119.5
   734.0   +5.06   +2.01   +5.09   +0.69   +1.79  +0.64  -0.14  119.6
   736.0   +1.46   -1.88   +3.77   -0.74   +1.19  +0.36  -0.12  119.6
   738.0   +5.30   +2.15   +5.15   +0.74   +1.90  +0.73  -0.14  119.7
```

De-trended peak-to-peak over t = 700–740 s: **steering 6.30°, request 10.05 mrad**;
raw yaw 4.26 °/s and lateral accel 2.27 m/s² (those two include the right-hand bend the
car enters after ~725 s).

---

## 4. Why this is a control loop, not the road

1. **The road is straight.** De-trended camera curvature RMS in the worst drive1 windows
   is 0.11–0.22 ×10⁻³ 1/m — radius 4500–9000 m. The weave is an order of magnitude
   larger than anything the road geometry asks for.
2. **The request leads the response.** `LaRefAng_No_Req` → yaw lag is **+0.1 … +0.2 s**
   with cross-correlation **+0.87 … +0.93** in the clean high-speed windows. The camera
   commands, the car follows. (One window, `t = 480 s`, gives +1.6 s / +0.35 — a poor
   fit, not evidence either way.)
3. **The driver is not doing it.** `TorsionBarTorque` RMS is 0.12–0.47 Nm in those
   windows — hands resting, no steering input of the size needed.
4. **No sensing dropouts.** Both lane lines are continuously tracked
   (`L = Not overridable`, `R = Overridable`), no `No line`, no LKA suppression, for the
   whole excerpt.

### Estimated lane excursion

Nothing on the bus reports lateral offset, so this is **derived**, not measured:
integrating a sinusoidal yaw of amplitude *ω* at frequency *f* gives heading amplitude
*ω*/(2π*f*), lateral speed *v*·sin(heading), and excursion amplitude
*v*·heading/(2π*f*):

- typical window (yaw ampl ≈ 0.5 °/s, 0.22 Hz, 33 m/s) → **± 15 cm**
- worst window t = 720 s (yaw ampl ≈ 0.85 °/s) → **± 27 cm**, i.e. ~55 cm peak-to-peak
  inside a 3.5 m lane

---

## 5. Frequency vs speed — unresolved

| window | speed | f | period | wavelength |
|---|---|---|---|---|
| drive1 t=720 | 120 km/h | 0.215 | 4.7 s | 155 m |
| drive1 t=700 | 120 km/h | 0.220 | 4.5 s | 151 m |
| drive1 t=640 | 119 km/h | 0.245 | 4.1 s | 135 m |
| drive1 t=940 | 93 km/h | 0.185 | 5.4 s | 140 m |
| drive2 t=1740 | 68 km/h | 0.230 | 4.3 s | **81 m** |

Within drive1 alone (93–120 km/h) the wavelength looks roughly constant (~135–155 m),
which would point at a camera **look-ahead distance**. But the single drive2 window at
68 km/h holds the same ~0.23 Hz, i.e. a constant **time** period, which would point at a
fixed controller time constant instead. The speed range is too narrow and the drive2
sample too small to discriminate. A deliberate speed sweep is needed (§6).

---

## 6. What is NOT established, and the control that would settle it

- **No matched manual-driving control exists in either capture.** The only non-LCA
  windows above 35 km/h in drive1 are three at 45.6 km/h on a twisty road (steering RMS
  8.98°, yaw RMS 2.19 °/s) — not comparable to a 120 km/h straight. So the statement
  "the system weaves more than a human would" is *not* proven here; what is proven is
  that the camera's request leads the motion on a straight road.
- **The mechanism inside the IPMA is untouched** — nothing here localises a gain, a
  filter or a look-ahead term in the firmware.

**Control experiment (one drive, ~10 minutes):**

1. Pick a straight, well-marked road allowing a steady 110–120 km/h.
2. Pass A: LCA active, hold speed, hands resting, 2 minutes. Log `can0` (and `can1`).
3. Pass B: same stretch, same speed, lane assist deselected in the menu, driver steering,
   2 minutes.
4. Repeat A at ~60 and ~80 km/h on the same stretch for the frequency-vs-speed question.
5. Optionally repeat A with `LaMenuSens_B_Actl` toggled (*High (early)* vs
   *Normal (late)*) — it read *High* in both existing captures.

If the 0.2 Hz content vanishes in pass B, it is the LCA controller. If the period stays
at ~4.5 s across 60/80/120 km/h it is a time constant; if the wavelength stays at ~145 m
it is a look-ahead distance. Either answer points at a different part of the firmware.

---

## 7. Reproducing

```bash
cd /home/gl/Projects/ford/IPMA/Research/work/drive
python3 extract.py ../../hscan_lka_lca_drive1.log ../../mscan_lka_lca_drive1.log drive1.json
python3 build.py   drive1.json ../../drive1_dashboard.html
python3 analyze_osc.py drive1.json drive2.json
```

In `drive1_dashboard.html` the oscillation is visible directly: open the window
**t = 700–740 s** and compare the *Lane-centering steering request* panel with
*Steering angle and steering rate* and *Vehicle dynamics*. The de-trending is only needed
for the numbers; the raw traces show the hunting plainly at that zoom.
