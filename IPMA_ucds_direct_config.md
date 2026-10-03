# IPMA — UCDS "Direct Configuration" screen, wire protocol and FD05 layout

Reference for reading the IPMA (0x706 / resp 0x70E) configuration set the way
UCDS does it, and the **solved byte layout of DID FD05 "Calibration Data"**
(camera alignment).

Source capture: `ucds_ipma_read_config.log` (candump, can0 = HS CAN), UCDS
Direct Configuration → module IPMA, `Read From module`, vehicle C520 EU MY17,
IPMA F1FT (rel 4.93.06).

---

## 1. The screen

UCDS lists ten configuration pages for the IPMA; each page is exactly one DID:

| # | UCDS page name | DID | read result in this capture |
|---|---|---|---|
| 1 | Critical Software Parameter Monitoring #1 | `D700` | 4 B |
| 2 | Critical Software Parameter Monitoring #2 | `D701` | 4 B |
| 3 | IO Activation | `FD08` | **NRC 0x31 requestOutOfRange** (not readable) |
| 4 | AHBC Online Calibration Data | `FD07` | 16 B |
| 5 | LDW Online Calibration Data | `FD06` | 16 B |
| 6 | **Calibration Data** | `FD05` | **20 B — solved below** |
| 7 | Vehicle Parameters | `DE00` | 8 B |
| 8 | Vehicle Parameters 2 | `DE01` | 12 B |
| 9 | Feature Options | `DE02` | 15 B |
| 10 | DTC Mask | `DE03` | 12 B |

`DE00`–`DE03` are the As-Built blocks (706-01-xx … 706-04-xx).
`D7xx` / `FDxx` are **not** in the As-Built record — they are live module state
exposed only through this Direct Configuration screen.

## 2. Session the tool opens before reading

Plain UDS over ISO-TP, 8-byte padded frames, no sub-function suppression:

```
706 10 01            -> 70E 50 01 00 32 01 F4     default session (P2=50ms, P2*=5000ms)
706 10 03            -> 70E 50 03 00 32 01 F4     extendedDiagnostic
706 27 03            -> 70E 67 03 36 36 B8        SecurityAccess seed  (level 3/4)
706 27 04 52 BE 4B   -> 70E 67 04                 key accepted
706 22 <DID>         -> 70E 62 <DID> <data...>    the ten reads
706 10 01            -> 70E 50 01 ...             back to default
```

The 3-byte seed/key pair is the ordinary Ford level-3 algorithm already used by
`VBFlasher/ford_seckey.py`. **Security access is required even to read** these
DIDs — a bare `22 FD05` in default session is rejected.

`FD08` (IO Activation) answers `7F 22 31` on read: it is a write/routine page,
not a readable record.

## 3. Reassembled responses (this capture)

```
62 D7 00 | 02 01 01 01
62 D7 01 | 01 02 00 01
62 FD 08 | 7F 22 31                      (negative)
62 FD 07 | 00 22 AC A1 BE 91 A9 10 00 00 00 00 3E F4 A9 3D
62 FD 06 | 05 05 05 00 3A C8 89 05 BF 04 5B 4B 3F 01 0E 2E
62 FD 05 | 40 5F 13 B3 3E 93 C5 8A 3E A7 5A EB 05 A2 FF FB 03 0A 00 00
62 DE 00 | 08 03 01 02 01 21 01 00
62 DE 01 | 2A 3F 01 3F 00 00 00 00 00 00 00 00
62 DE 02 | 01 01 01 02 01 01 03 01 03 03 03 00 00 00 01
62 DE 03 | 00 00 00 00 00 00 00 00 00 00 00 00
```

---

## 4. FD05 "Calibration Data" — SOLVED

20 bytes, big-endian, fixed layout. Every one of the seven fields UCDS shows
reproduces **exactly** from these bytes:

| off | size | type | field (UCDS label) | raw (this car) | decoded | UCDS shows |
|---|---|---|---|---|---|---|
| 0x00 | 4 | IEEE-754 float32 BE | Sensor Pitch Angle | `40 5F 13 B3` | 3.485577 | `3,485577` |
| 0x04 | 4 | IEEE-754 float32 BE | Sensor Roll Angle | `3E 93 C5 8A` | 0.288616 | `0,288616` |
| 0x08 | 4 | IEEE-754 float32 BE | Sensor Yaw Angle | `3E A7 5A EB` | 0.326866 | `0,326866` |
| 0x0C | 2 | uint16 BE | Sensor Socket Z [mm] | `05 A2` | 1442 | `1442` |
| 0x0E | 2 | uint16 BE | Sensor Socket Y [mm] | `FF FB` | 65531 | `65531` |
| 0x10 | 2 | uint16 BE | Sensor Socket X [mm] | `03 0A` | 778 | `778` |
| 0x12 | 2 | uint16 BE | Quality (degrees) | `00 00` | 0 | `0` |

Notes:

- **Angles are raw float32, no scaling factor**, units degrees. Match is to the
  last displayed digit (UCDS prints 6 decimals of the float32).
- **Socket Y is really signed.** `FF FB` displayed as 65531 is UCDS printing an
  unsigned u16; the physical value is **−5 mm**. X and Z are positive here so
  the sign convention cannot be distinguished from this sample alone, but a
  single int16 type for all three is the only consistent reading.
  Geometry is the usual camera-mount frame: Z ≈ 1442 mm = camera height,
  X ≈ 778 mm = longitudinal offset from the front axle, Y ≈ −5 mm = lateral
  offset from vehicle centreline.
- **Quality** occupies the final 2 bytes by exhaustion (20 − 18). It is 0 on
  this module, so its scaling is unconfirmed; the label says degrees, so a
  residual-error figure in the same units as the angles is the natural reading.

Decoder, one line:

```python
import struct
pitch, roll, yaw = struct.unpack('>fff', d[0:12])
z, y, x, quality = struct.unpack('>hhhH', d[12:20])   # mm, mm, mm
```

### Why this is certain

Seven independent constraints (3 floats + 4 integers) are satisfied
simultaneously by one 20-byte big-endian reading with no free parameters: the
float exponents land in a plausible range only at offsets 0/4/8, and the three
millimetre values appear nowhere else in the payload. No alternative alignment
reproduces `3,485577`.

---

## 5. FD06 / FD07 — same shape, partially read

Both are 16 bytes and decode cleanly as **4-byte header + 3 × float32 BE**:

| DID | header | float[0] | float[1] | float[2] |
|---|---|---|---|---|
| `FD06` LDW Online Calibration | `05 05 05 00` | 0.001530 | −0.517018 | 0.504123 |
| `FD07` AHBC Online Calibration | `00 22 AC A1` | −0.284493 | 0.000000 | 0.477854 |

The float triple is almost certainly the online-learned pitch/roll/yaw
correction that the module accumulates while driving (LDW = lane camera,
AHBC = auto high-beam). The header is unresolved: on FD06 it looks like three
status/confidence bytes (`05 05 05`) plus a pad; on FD07 the three bytes
`22 AC A1` behave like a counter. **Field names for FD06/FD07 are not captured
here** — reading them needs a screenshot of pages 4 and 5. Do not write these
DIDs on the strength of this decode.

## 6. Relation to the speed-gate work

This confirms, with the actual byte layout, the negative result in
`IPMA_config_and_flash_risk.md`: the only numerically meaningful configuration
surface on the IPMA is **camera geometry and alignment**, not behaviour
thresholds. FD05/FD06/FD07 are mounting/alignment data; `DE00`–`DE02` are the
35 bytes of enumerated feature flags. Nothing in the Direct Configuration set
can move the LKA/LCA activation speeds — that remains a firmware constant
(see `IPMA_speed_gates.md`, `F1FT_speed_gates.md`).

FD05 is, however, the right place to look if camera aim ever needs correcting
after a windscreen change: it is the stored static alignment, and UCDS offers
`Write to Module` for it.

**Update — the write path is now traced in the firmware.** `0x2E` is implemented
for exactly these ten DIDs, `FD05`'s write handler is `0x0328C8`, it stores to
NVM blocks 40 (angles, radians) and 42 (offsets, metres) with hard range
limits, and those blocks are loaded at init into the parameter block that is
pushed to the DSP — so the values are live inputs to the vision pipeline, not
just reported state. Also resolves the Socket Y signedness question above:
Y is stored as `−Y_mm/1000` metres and clamped to ±200 mm, so `FF FB` is
unambiguously **−5 mm**. See
[IPMA_camera_alignment.md](IPMA_camera_alignment.md).
