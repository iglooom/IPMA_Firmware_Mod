# IPMA camera alignment — the writable geometry set, and proof the firmware uses it

Reference for correcting the mounting geometry of a **retrofitted F1FT IPMA**
(rel 4.93.06, app `F1FT-14F397-AG`) on a C520.

Answers two questions:

1. **What can actually be set?** — `FD05` (static mount geometry), `FD06`/`FD07`
   (online-learned corrections), and nothing else. Exact fields, units, sign
   conventions and the firmware-enforced limits are below.
2. **Does the firmware use it, or is it only a reported value?** — it uses it.
   The stored values are loaded at init into a runtime parameter block that is
   handed to the DSP (vision) processor. Call chain traced below.

Everything here is derived from `work/f1ft/app/F1FT-14F397-AG_blk0_0x00010000.bin`
(addresses are load addresses, app base `0x00010000`) plus the two UCDS captures
`ucds_ipma_read_config.log` and `../ucds share/Direct_IPMA_221024_.xml`.

---

## 1. The configuration surface — 10 writable DIDs, and that is all

The app holds two independent DID tables.

**Read table** (`0x22 ReadDataByIdentifier`) — 58 entries at `0x0DA238`,
16 bytes each, binary-searched by `0x037904`:

```
+0x00  u16  DID
+0x02  u16  response length          (fetched by 0x0378A8)
+0x04  u8   access/condition byte
+0x08  u32  0xF0000000  access descriptor (checked by 0x0378B8)
+0x0C  u32  read handler             (called via `jl` from the 0x22 service)
```

**Write table** (`0x2E WriteDataByIdentifier`) — the service-descriptor rows at
`0x0DA118 … 0x0DA1B7`, ten rows, all carrying access byte `0x48`, keyed by the
ten-entry DID list at `0x0DA87E`:

| # | DID | UCDS page | data len | write handler | NVM block written |
|---|---|---|---|---|---|
| 0 | `D700` | Critical Software Parameter Monitoring #1 | 4 | `0x0324B8` | — |
| 1 | `D701` | Critical Software Parameter Monitoring #2 | 4 | `0x032590` | — |
| 2 | `DE00` | Vehicle Parameters | 8 | `0x032668` | As-Built |
| 3 | `DE01` | Vehicle Parameters 2 | 12 | `0x032700` | As-Built |
| 4 | `DE02` | Feature Options | 15 | `0x032798` | As-Built |
| 5 | `DE03` | DTC Mask | 12 | `0x032830` | As-Built |
| 6 | **`FD05`** | **Calibration Data** | **20** | **`0x0328C8`** | **40 + 42** |
| 7 | `FD06` | LDW Online Calibration Data | 16 | `0x032B08` | 62 |
| 8 | `FD07` | AHBC Online Calibration Data | 16 | `0x032C68` | 78 |
| 9 | `FD08` | IO Activation | 2 | `0x032DC8` | none (immediate action) |

The declared request lengths in the write rows (7, 7, 11, 15, 18, 15, **23**,
19, 19, 5 = `3 + data`) reproduce the read-table lengths of the same ten DIDs
one-for-one. That is what pins the DID→handler mapping; no other table in the
image references `FD05`.

Consequences:

* **`FD05` is the only knob for static camera geometry.** Nothing else in the
  module exposes pitch/roll/yaw or mount offsets.
* `FD08` is write-only (2 bytes) — hence `7F 22 31` when UCDS reads it.
* Everything on the *Monitor* screen (`41BB` Camera Alignment Status, `FD0F`
  Calibration Status, `FD0B` Camera Parameters, `FD21` Intrinsic Sensor
  Tolerances, `FD15`/`41BA`/`FD16` ride heights) is **read-only** — absent from
  the write table.

---

## 2. `FD05` — layout, units, internal representation, hard limits

20 bytes, big-endian. The DID is a *computed view*: the module stores the data
in two NVM blocks in SI units, and converts on every read and write.

| off | size | DID field | DID unit | stored as | NVM |
|---|---|---|---|---|---|
| `0x00` | 4 | Sensor Pitch Angle | float32 **degrees** | radians | blk 40 w0 |
| `0x04` | 4 | Sensor Roll Angle | float32 **degrees** | radians | blk 40 w1 |
| `0x08` | 4 | Sensor Yaw Angle | float32 **degrees** | radians | blk 40 w2 |
| `0x0C` | 2 | Sensor Socket Z | int16 **mm** | `+z` metres | blk 42 w2 |
| `0x0E` | 2 | Sensor Socket Y | int16 **mm** | `−y` metres | blk 42 w1 |
| `0x10` | 2 | Sensor Socket X | int16 **mm** | `−x` metres | blk 42 w0 |
| `0x12` | 1 | (always 0) | — | not stored | — |
| `0x13` | 1 | Quality | u8 | status byte | blk 40 +12 **and** blk 42 +12 |

Conversions, with the literal constants from the code:

```
read  (0x033F4C)   deg = rad * 57.2957795   (0x42652EE1)
                   X_mm = round(w0 * -1000.0)   (0xC47A0000)
                   Y_mm = round(w1 * -1000.0)
                   Z_mm = round(w2 * +1000.0)   (0x447A0000)

write (0x0328C8)   rad = deg * 0.017453292  (0x3C8EFA35)
                   w0  = X_mm * -0.001       (0xBA83126F)
                   w1  = Y_mm * -0.001
                   w2  = Z_mm * +0.001       (0x3A83126F)
```

Internal frame is therefore `x` forward-positive, `z` up-positive, `y` the
remaining right-handed axis, origin on the vehicle reference; the DID negates
X and Y. **Which way DID-Y positive points (left or right) is not established
by static analysis** — see §6.

### All three offsets are int16 — UCDS prints them unsigned

The write handler sign-extends every offset field with an *arithmetic* shift
(Y at `0x0329E4`, X at `0x03299C`, Z at `0x032A2C`):

```
ldub r3,@(14,r4) ; slli r3,#8 ; ldub r0,@(15,r4) ; or r3,r0
slli r3,#0x10    ; srai r3,#0x10          <-- srai, not srli: s16
```

and the read handler stores the rounded signed result with `sth`, so an
internal `y = +0.005 m` comes out as `FF FB`. UCDS formats those bytes with an
unsigned conversion and displays **65531**; the stored value is **−5 mm**. Two
further confirmations that 65531 is a display artefact and not the real datum:
the accepted Y range is the symmetric ±200 mm (`0xC3480000` / `0x43480000`), and
a literal 65531 would therefore be rejected with `7F 2E 31` by the module's own
validator.

The round trip is nevertheless harmless — writing back `65531` as a u16 emits
the same `FF FB` and the handler sign-extends it to −5. The only trap is data
entry: if the tool refuses a negative number, type the two's-complement value
(−5 → 65531, −25 → 65511 = `FF E7`).

Same issue one field over: UCDS labels bytes `0x12..0x13` "Quality (degrees)"
and reads them as a u16, but the read handler forces `0x12` to zero and copies
the NVM status byte into `0x13`. It is a **1-byte status code**, not a degree
value; it only renders plausibly because the high byte is hardcoded 0.

X and Z are signed by the same code path, but their ranges (0…2000 and
500…2000 mm) keep them positive in practice, so only Y exposes the bug.

### Firmware-enforced limits (violation ⇒ `7F 2E 31` requestOutOfRange)

Each field is range-checked *before* anything is written; a single bad field
rejects the whole request and nothing is stored.

| field | min | max | constants |
|---|---|---|---|
| Pitch | −5.0° | +5.0° | `0xC0A00000` / `0x40A00000` |
| Roll | −5.0° | +5.0° | same pair |
| Yaw | −5.0° | +5.0° | same pair |
| Socket Z | +500 mm | +2000 mm | `0x43FA0000` / `0x44FA0000` |
| Socket Y | −200 mm | +200 mm | `0xC3480000` / `0x43480000` |
| Socket X | 0 mm | +2000 mm | integer 0 / `0x44FA0000` |

A NVM write failure after validation returns `7F 2E 22` conditionsNotCorrect.

### ROM fallback defaults (used when NVM is unreadable)

From the NVM block-descriptor table at `0x000E2448` (16 B/entry:
`+0x04` u16 length, `+0x08` u32 default-data pointer):

| blk | len | default ptr | decoded |
|---|---|---|---|
| 40 | 13 | `0x000E2354` | pitch **1.000°**, roll 0°, yaw 0°, status `0xFF` |
| 42 | 13 | `0x000E2364` | X **1160.8 mm**, Y **−3.25 mm**, Z **1320.5 mm**, status `0xFF` |

### Observed real-vehicle values

| vehicle | pitch | roll | yaw | Z | Y | X | qual |
|---|---|---|---|---|---|---|---|
| C520 MY17, F1FT (this car) | 3.485577° | 0.288616° | 0.326866° | 1442 | **−5** | 778 | 0 |
| C346 MY11.25 (other sample) | 0.601110° | −0.162066° | −0.170400° | 1299 | **−4** | 815 | 29 |
| ROM default | 1.000° | 0° | 0° | 1320.5 | **−3.25** | 1160.8 | — |

Three independent samples put Y within ±5 mm of the centreline, which confirms
Y is the lateral mount offset and that a 20 mm bracket shift is a large change
relative to the nominal value.

**Round-trip caveat:** writing back the exact bytes just read can shift a value
by 1 LSB, because of the mm→m→mm and deg→rad→deg conversions. The UCDS export
`Direct_IPMA_F1FT_290926_.xml` shows this — Z reads `05A2` (1442) but the
written/exported copy is `05A3` (1443).

---

## 3. Proof the firmware consumes it (not just reports it)

`0x08904C` is `NvM_Read(blockId = r4, dst = r5, flag = r6)`; `0x08A1DC` and
`0x0891E0` are the write/blocking-read siblings. Scanning every call site for
blocks 40 and 42 gives exactly four readers and three writers — and only one
reader is diagnostic:

```
read  0x033F74 / 0x033F84    FD05 read handler              (diagnostic)
read  0x0A7888 / 0x0A784C    0x0A77B0  camera-geometry init  <-- RUNTIME
write 0x032AD0 / 0x032AE0    FD05 write handler             (diagnostic)
write 0x0ACFA8 / 0x0AD0FC    module's own NVM write-back
read  0x0ACD00 / 0x0ACD50    module's own NVM read-back
```

The runtime consumer, `0x0A77B0`, is a one-shot initialiser (guard flag
`0x00805A58`, up to 15 retries counted at `0x00805A54`) that fills a parameter
structure:

```
blk  0  (7 B)   -> struct +0x0C
blk  1  (u16)   -> struct +0x14
blk 42          -> struct +0x60 = w0 (x)   +0x5C = w1 (y)   +0x58 = w2 (z)
                   +0x64 = status byte
blk 40          -> struct +0x48 = pitch    +0x4C = roll     +0x50 = yaw
                   +0x54 = status byte
blk 206 (u8)    -> struct +0x7A
```

and its caller `0x0A7928` then ships that structure off-chip:

```
0A7920  ld24 r0,0x0082BBFC          ; the parameter structure
0A7934  bl   0x0A77B0               ; fill it from NVM blocks 0,1,40,42,206
0A793C  bl   0x00082F08  (r4=128)
0A7940  ld24 r4,0x800F3000          ; shared-memory / DSP channel id
0A7948  bl   0x000A9560             ; id -> channel descriptor (5-entry table @0x00805C4C)
0A7954  bl   0x00083088  (r4=chan, r5=struct)   ; -> 0x000828D4, IPC send
```

So the stored pitch/roll/yaw and the X/Y/Z mount offsets are read once at
start-up, packed with the rest of the camera parameter block, and pushed to the
DSP that runs the lane/sign/high-beam vision pipeline. **They are live inputs to
the image processing, not cosmetic diagnostic data.**

Two practical corollaries:

* **A new value only takes effect after a module reset / ignition cycle**, since
  `0x0A77B0` is one-shot and runs at init. Follow a write with `11 01` or a
  proper key-off.
* The module has **its own write-back path** for blocks 40/42 (`0x0ACF64`,
  reached from the main application task tree at `0x0A7FB0`, not from any
  diagnostic service). Treat a hand-written `FD05` as changeable: re-read it
  after a few drive cycles to confirm it stuck.

`FD06` (blk 62) and `FD07` (blk 78) are the separately-stored online-learned
corrections for the LDW and AHBC paths; their write handlers apply the same
±5.0° clamp plus a per-field bounds array. Do not write them — the module
maintains them.

---

## 4. How to write `FD05`

Same session/security dance UCDS uses for the Direct Configuration screen
(security access is required even to *read* these DIDs):

```
706 10 03                       -> 70E 50 03 ...        extendedDiagnostic
706 27 03                       -> 70E 67 03 <3-byte seed>
706 27 04 <3-byte key>          -> 70E 67 04            (VBFlasher/ford_seckey.py, level 3)
706 2E FD 05 <20 bytes>         -> 70E 6E FD 05         (ISO-TP multi-frame, 23 B total)
706 11 01                       -> 70E 51 01            reset so 0x0A77B0 re-reads NVM
706 22 FD 05                    -> verify what came back
```

Negative responses: `7F 2E 31` = a field outside the §2 limits (nothing
written); `7F 2E 22` = NVM write refused; `7F 2E 33`/`7F 2E 7F` = security or
session missing.

### SecurityAccess level 3/4 secret — solved

The configuration DIDs use `27 03` / `27 04`, **not** the level-1 pair used for
flashing. Solved from the two captured seed/key pairs with
`work/ford_seckey_solve.py`:

```
level 1 (flash, 27 01/02)   secret 0x00009875CA   (IPMA_flashing.md)
level 3 (config, 27 03/04)  secret 0x0000E727FB   <-- this
```

```
$ python3 work/ford_seckey_solve.py --pair 3636b8:52be4b --pair 1c8aba:7bb0bf
solved secret: 0x0000e727fb   (16 free bits -> 65536 equivalent secrets, identical keys)
VERIFIED against all 2 captured pair(s).
```

Same universal algorithm (`VBFlasher/ford_seckey.py`,
`key_from_seed(seed3, 0x0000E727FB)`), so `FD05` can be written from a script
without UCDS.

### Confirmed write transaction (`ucds_ipma_write_dids.log`)

Setting Socket Y to +150 mm, reassembled from the candump:

```
706 10 01                 -> 70E 50 01 00 32 01 F4
706 10 03                 -> 70E 50 03 00 32 01 F4
706 27 03                 -> 70E 67 03 1C 8A BA
706 27 04 7B B0 BF        -> 70E 67 04
706 2E FD 05 40 5F 13 B3 3E 93 C5 8A 3E A7 5A EB 05 A2 00 96 03 0A 00 00
                          -> 70E 6E FD 05            (ISO-TP FF len 0x17 + 3 CF)
```

`6E FD 05` is returned only after **both** NVM writes come back zero — the
handler emits `7F 2E 31` before writing anything if validation fails and
`7F 2E 22` if either `NvM_Write` is refused. So blocks 40 and 42 are both
committed.

`NvM_Write` (`0x0008A1DC`) additionally checks block id < 287, a non-null
source, and a read-only flag in the descriptor's `+0x0C` word (bit clear =
writable; blocks 40/42 are clear). Error codes it can return: 3 bad id,
4 null source, 6 not initialised, 31 read-only.

**Two things the capture does not contain:** no `11 01` / key cycle, and no
read-back. Both are needed — see §3, the runtime copy is loaded once at init.

**Current bytes on this car (restore value — keep this):**

```
40 5F 13 B3  3E 93 C5 8A  3E A7 5A EB  05 A2  FF FB  03 0A  00 00
pitch 3.485577  roll 0.288616  yaw 0.326866   Z 1442  Y -5  X 778  qual 0
```

Only the two bytes at `0x0E..0x0F` change for a pure lateral correction:

| Socket Y | bytes | meaning |
|---|---|---|
| −5 mm | `FF FB` | as stored now (OEM bracket, slightly left of centreline) |
| **+150 mm** | **`00 96`** | **measured mount of this retrofit, 150 mm right** |
| +200 / −200 mm | `00 C8` / `FF 38` | the firmware limits |

Sign convention: **positive = right of centreline** (established in §6).
Full 20-byte payload for the measured +150 mm:

```
40 5F 13 B3  3E 93 C5 8A  3E A7 5A EB  05 A2  00 96  03 0A  00 00
```

---

## 5. What is worth correcting, quantitatively

A retrofit bracket introduces two different errors, and they are not equally
important:

* **Pure lateral translation** (the camera sits off where the module thinks it
  is). The module adds Socket Y to the measured camera-to-lane distance to get
  the vehicle's lane position, so the error appears as a **constant lane-position
  bias of exactly that size**. Whether this matters is entirely a question of
  magnitude: a 20 mm bracket error is lost in a ~3.5 m lane and an LKA deadband
  of tens of centimetres, but the **155 mm** error measured on this vehicle
  (mount 150 mm right, stored −5 mm) is ~18 % of the free space either side of
  a 1.8 m-wide car in a 3.5 m lane — worth correcting. See §6 for the signed
  propagation and the on-road check.
* **Yaw (aim) error θ.** The lane's lateral position at look-ahead distance `d`
  is misplaced by `d·θ`, and the lane heading angle is misestimated by θ
  outright. At a 25 m look-ahead, **0.5° of yaw ≈ 220 mm** of apparent lane
  offset — three orders of magnitude more consequential than the 20 mm
  translation.

So if the retrofit bracket only *translated* the camera, correcting Socket Y is
cosmetic. If it also *rotated* it — which a 2 cm sideways shift on a windscreen
bracket usually implies — the Sensor Yaw Angle is the parameter that matters,
and pitch matters for range estimation. Both are inside `FD05` with ±5° of
authority, which is ample.

---

## 6. Sign convention — RESOLVED

Static analysis fixes the magnitude and the internal scaling exactly, but left
two self-consistent readings of which direction DID-Y positive points. **An
on-vehicle measurement settles it:**

* the OEM bracket on this platform sits slightly **left** of the centreline, and
  the OEM-stored value is **Y = −5 mm** (ROM default −3.25 mm, a second C346
  sample −4 mm — all three left of centre);
* therefore **DID Y negative = camera left of centreline, positive = right**.

Cross-check on the internal frame: `y_internal = −Y_mm/1000`, so Y = −5 gives
`y_internal = +0.005`. With `x` forward-positive and `z` up-positive already
established from the read/write scaling, the internal frame is
**(x forward, y left, z up)** — the standard DIN 70000 / ISO 8855 right-handed
vehicle frame. The DID negates X and Y relative to it, so:

| DID field | positive means |
|---|---|
| Socket X | camera **rearward** of the vehicle origin |
| Socket Y | camera **right** of the centreline |
| Socket Z | camera **above** the origin (height) |

### Error propagation, and the on-road check

Write `v` for the vehicle's lateral offset from lane centre (positive = right),
`c` for the camera's measured offset from lane centre, `b` for the stored
Socket Y. The module reports `v = c − b`, so a stored `b` that is wrong by Δ
makes the reported position wrong by −Δ, and a lane-centring controller driving
the reported value to zero parks the car **Δ to the left** of lane centre.

Worked case for this vehicle — measured mount 150 mm right, stored −5 mm,
Δ = 155 mm:

| stored Y | predicted steady-state lane position under LKA/LCA |
|---|---|
| `FF FB` (−5, as found) | ≈ 155 mm **left** of lane centre |
| `00 96` (+150, correct) | centred |
| `FF 6A` (−150, sign inverted) | ≈ 300 mm **left** |

This is the positive control for the sign: 155 mm is directly observable from
the driver's seat, and an inverted sign roughly doubles the error instead of
removing it. **Caveat on the chain:** the `v = c − b` step is the only reason
the parameter exists and the DSP demonstrably receives x/y/z in the init struct
(§3), but the arithmetic itself has not been traced — the DSP part is
compressed and was never disassembled. The road observation is the evidence.

### A lateral relocation is never only lateral

A windscreen is raked and curved in both axes, so a bracket moved 150 mm
sideways also sits at a different glass angle and a different point in space.
Expect **roll** to move most (sideways travel on a laterally curved screen tilts
the camera about the longitudinal axis), **pitch** to move with the local rake,
and **X / Z** to shift as well. Correcting Y alone leaves roll and pitch errors
feeding range and curvature estimation. Measure all five; the ±5° clamp on the
angles is generous enough for any realistic bracket.

---

## 7. The OEM IDS alignment procedure — what it actually does

Captured in `ids_ipma_calib.log` (C520 MY17, F1FT). This is the factory way to
*produce* the `FD05` content, so it bounds what a hand-written value is worth.

### Phase 1 — session, security, keepalive (lines 1–46)

```
706 10 03                 extendedDiagnostic
706 27 03  -> 67 03 69 62 92     706 27 04 51 82 69  -> 67 04
706 3E 00  x3                    (3 s TesterPresent while the dialog is open)
706 10 03 / 27 03 -> 7E 6C 45 / 27 04 AA 0C A0 -> 67 04
706 3E 00  x14                   (operator typing the wheel-arch heights)
```

**Both IDS seed/key pairs verify against the level-3 secret `0x0000E727FB`
solved from the UCDS captures** (§4) — `696292→518269` and `7E6C45→AA0CA0`.
Four verified pairs now, from two independent tools.

### Phase 2 — the one command that matters (line 49)

```
706 31 01 20 50  03 16 03 16 03 2A 03 2A      -> 70E 71 01 20 50 10
```

`RoutineControl startRoutine`, routine **`0x2050`**, 8 bytes of payload =
**4 × u16 BE wheel-arch heights in mm**: `790, 790, 810, 810`, in the same
**FL, FR, RL, RR** order as `41BA` / `FD15`. Reply is one status byte `0x10`.

Routine table (resolved at `0x0DA800` ids / `0x0DA670` entries, dispatched via
the subfunction→column map at `0x0DA89F` + the 3-column row table at
`0x0DA8A3`; `0x17` = unsupported):

| routine | startRoutine | stopRoutine | requestRoutineResults |
|---|---|---|---|
| `0202` | `0x035174` | `0x035210` | `0x035264` |
| `0301` | `0x035424` | — | — |
| `0304` | `0x03546C` | — | — |
| `201B` | `0x0354B4` | — | — |
| `204E` | `0x035514` | — | `0x0356E4` |
| `204F` | `0x03596C` | — | — |
| **`2050`** | **`0x035CA8`** | — | — |
| `DC00` / `DC01` | `0x035D88` / `0x035DE0` | — | — |
| `F002`…`F009` | `0x035ED4`…`0x0359C0` | — | `F008`: `0x036370` |
| `FF00` / `FF01` | `0x036574` / `0x0365D4` | — | — |

Handler `0x035CA8`:

* requires **exactly 8** payload bytes, else NRC `0x13`
  incorrectMessageLengthOrInvalidFormat;
* unpacks the four u16;
* **toggles** bit `0x40` of the global flag word at `0x008041A8`
  (`0x038644` = set, `0x038668` = xor-clear, `0x038630` = read masked). If the
  bit was already set it is *cleared* and `−7` is written to the status byte at
  `0x008041A6` — i.e. **sending the routine a second time aborts the
  alignment**, it is not an idempotent "start";
* calls `0x0ACE94`, which under mutex 2 stores the four heights into the
  alignment subsystem's working struct at **`0x0082C178`**, offsets `+0x10`,
  `+0x12`, `+0x14`, `+0x16`, plus a validity word at `+0x18`;
* answers status `0x10`.

**It writes no NVM.** The heights live only in RAM at this point.

### Phase 3 — the drive, polled through `41BB` (lines 55+)

IDS sends `3E 80` (suppressed-response TesterPresent) and then polls
`22 41BB` at ~4 Hz, getting `62 41BB 01 00` throughout the capture (it read
`00 00` before the routine).

`41BB` "Camera Alignment Status" is built by handler `0x03319C` from the
alignment state word at **`0x008064E8`**:

| byte | meaning |
|---|---|
| 0 | state, remapped `2→1`, `3→3`, `4→2`, anything else `→0`. `00` = idle, **`01` = running, `02` = complete** |
| 1 | progress, a 0–100 % figure (`0x01283C`) bucketed into six steps: `<20→0`, `20–39→1`, `40–59→2`, `60–79→3`, `80–99→4`, `≥100→5` |

So IDS is watching a six-step progress bar. `01 00` = running, under 20 % done.
State `3` (internal 3) has never been observed; failure/abort is the obvious
candidate but it is not confirmed.

### Phase 4 — what happens on convergence

The module that owns struct `0x0082C178` also contains the NVM read-back
`0x0ACCE0` (blocks 42 → `+0x30…+0x40`, 40 → `+0x44…+0x54`) and the write-back
`0x0ACF64` / `0x0AD0FC` (blocks 42 and 40). **Blocks 40 and 42 are exactly what
`FD05` reads and writes.** The procedure therefore ends by overwriting the
static alignment with the angles it learned from the lane markings.

The wheel-arch heights are the attitude reference: they fix the body's pitch
and roll relative to the road, which is what lets the module separate *body*
attitude from *camera* attitude in the learned image geometry. Enter them
wrong and the learned pitch is wrong by the same amount.

The heights are persisted separately in **NVM block 79**, which also backs
`41BA`, `FD0F` and `FD16` (`41BA` handler `0x033100` reads block 79 and takes
four u16 at block offsets `+18/+22/+26/+30`). Until the alignment completes and
block 79 is rewritten, `41BA` still reports the *previous* set — which makes it
a useful "did it commit" probe, independent of `41BB`.

### Observed outcome of a complete run

One full learn drive on the C520 F1FT, logged by `work/ipma_align.py run
--heights 790,790,810,810`:

```
t=  0.0s  41BB 00 00  idle         FD05 pitch +2.185000 roll +0.000000 yaw +0.000000
                                        Z 1480  Y +150  X 790  qual 255
t=  6.1s  41BB 01 00  running  (needs motion before it leaves idle)
t=140.4s  41BB 01 01  20-39%
t=262.8s  41BB 01 02  40-59%
t=306.5s  41BB 01 03  60-79%
t=345.1s  41BB 01 04  80-99%
t=392.9s  41BB 02 05  COMPLETE
          FD05 pitch +0.668917 roll +1.868521 yaw -1.849287
               Z 1480  Y +150  X 790  qual 0
          41BA 790/790/810/810   (persisted)
```

Four facts this settles:

* **State `02` = complete.** It appeared exactly with progress bucket 5.
* **The quality byte is a validity flag, not a measurement.** `0xFF` before
  (the same value as the ROM defaults, i.e. "never aligned") → `0x00` after a
  successful learn. The `29` seen on an unrelated C346 sample is unexplained by
  this reading.
* **Only the angles are rewritten.** `Z`, `Y` and `X` came through the
  procedure byte-identical, including a hand-written `Y = +150`. The earlier
  caveat "block 42 may be rewritten from an unseeded struct — verify rather
  than assume" is resolved empirically: **a hand-written mount offset survives
  an alignment.**
* **Roughly 6.5 minutes of driving**, non-linear: the first bucket took 134 s
  and the rest 40–50 s each, so it is marking-quality dependent rather than
  time- or distance-metered.

### Practical consequences

* **Do not re-send `31 01 2050`** to "make sure it started" — it toggles off.
* `41BB` byte 1 is the progress bar; `41BA` changing to the values you typed is
  the proof the result was persisted.
* The procedure **overwrites `FD05`**. Run it *before* hand-writing Socket Y,
  then re-read `FD05` to confirm the lateral value survived — block 42 is
  rewritten from a struct whose seeding was not fully traced, so verify rather
  than assume.
* Power-cycling mid-procedure loses the progress: nothing is in NVM until the
  end.

### Driving it without IDS — `work/ipma_align.py`

Reimplements the whole procedure on top of `VBFlasher/vbf.py` (ISO-TP) and the
level-3 secret in `ecu_db.py`:

```bash
python3 work/ipma_align.py status                       # decoded snapshot
python3 work/ipma_align.py run --heights 790,790,810,810 --log drive_align
python3 work/ipma_align.py abort                        # deliberate toggle-off
python3 work/ipma_align.py setgeom --y 150              # write FD05 fields
python3 work/ipma_align.py setgeom --restore <40 hex>   # put a value back
python3 work/ipma_align.py --selftest                   # 62 checks
```

`run` = `start` + `monitor`: it refuses to re-arm a running alignment (that
would abort it), polls `41BB` for state/progress, samples `FD05` to show the
angles converging with a delta against the starting value, watches `41BA` for
the persist, and logs JSONL + CSV. `setgeom` mirrors the firmware's range
checks client-side so an out-of-range field is rejected before it reaches the
bus. Self-tests replay `ids_ipma_calib.log`, `ucds_ipma_read_config.log` and
`ucds_ipma_write_dids.log`, verify all four captured seed/key pairs, and drive
every command against an in-process mock module.

---

## 8. Address summary

| what | address |
|---|---|
| Read-DID table (58 × 16 B) | `0x000DA238` |
| Read-DID binary search / length / access check | `0x00037904` / `0x000378A8` / `0x000378B8` |
| `0x22` service loop | `0x00037AE0` |
| Write-DID service rows (10, access `0x48`) | `0x000DA118` |
| Write-DID list (10 × u16) | `0x000DA87E` |
| `FD05` read handler | `0x00033F4C` |
| **`FD05` write handler** | **`0x000328C8`** |
| `FD06` / `FD07` / `FD08` write handlers | `0x00032B08` / `0x00032C68` / `0x00032DC8` |
| Routine id table (19 × u16) / entries (19 × 16 B) | `0x000DA800` / `0x000DA670` |
| Routine subfunction→column map / 3-column row table | `0x000DA89F` / `0x000DA8A3` |
| **Routine `0x2050` (set wheel-arch heights, start/abort alignment)** | **`0x00035CA8`** |
| Alignment arm/abort flag word (bit `0x40`) / status byte | `0x008041A8` / `0x008041A6` |
| Alignment working struct (heights at `+0x10`, stored alignment at `+0x30`) | `0x0082C178` |
| Alignment state word (drives `41BB`) | `0x008064E8` |
| `41BB` / `41BA` read handlers | `0x0003319C` / `0x00033100` |
| Heights + calibration-environment NVM block (`41BA`/`FD0F`/`FD16`) | block 79 |
| `NvM_Read(id, dst, flag)` | `0x0008904C` |
| `NvM_Write(id, src, flag)` | `0x0008A1DC` |
| NVM block descriptor table (16 B/entry) | `0x000E2448` |
| blk 40 / blk 42 ROM defaults | `0x000E2354` / `0x000E2364` |
| Camera-geometry runtime init | `0x000A77B0` |
| Runtime parameter structure | `0x0082BBFC` |
| DSP channel id / IPC send | `0x800F3000` / `0x00083088` |
| Module's own blk 40/42 write-back | `0x000ACF64` |
