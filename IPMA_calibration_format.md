# IPMA calibration container format

The "Application Parameters" part (`CV4T-14F398-AF`, 17 448 B, loads
`0x00003000`). **Memory address = `0x3000` + file offset.**

The block is **self-describing**: it declares its own regions and record
strides, so nothing here needs to be guessed by pattern-matching.

---

## 1. Data representation

**Big-endian IEEE-754 float32 throughout.** Proven, not assumed:

* Census over all 4362 aligned words: plausible-magnitude floats
  big-endian 3474 vs little-endian 399; floats rounding cleanly to 2 decimals
  **2690 vs 5**.
* Direct check at file `0x3348`: BE gives `80, 50, 180, 110, 5, 3, 5, 3`;
  LE gives `5.7e-41, 2.6e-41, 1.9e-41, 7.9e-41` — denormal garbage.
* Structural integers (addresses, sizes, tags) are big-endian too.

> **Pitfall that cost a full analysis round.** An integer scan for the u16
> values `400`/`500` found "hits at stride 0x408" and looked convincing. They
> were **float32 upper halves**: `0x3F80` = `1.0f`, `0x4120` = `10.0f`. The
> apparent stride was the genuine record stride crossing float boundaries.
> Always decode 4-byte aligned as `>f` before believing a 16-bit pattern.

---

## 2. Layout

```
0x0000 .. 0x012C   header: BootNfo descriptor + ASCII tags
0x008C             REGION INDEX      16-byte rows
0x012C .. 0x1A84   region tag 0x00000A00 (largest, un-decomposed)
  ...              tagged data regions
0x43A8             ELEMENT-SIZE TABLE  16-byte rows
0x4428             end
```

### Region index — file `0x008C`, rows of `[load_addr, size, flags, tag]`

Perfectly address-chained (`addr[n] + size[n] == addr[n+1]` for every row):

| load addr | size | flags | tag |
|---|---|---|---|
| `0x0312C` | `0x1958` | `0x00010001` | `0x00000A00` |
| `0x04A84` | `0x1020` | `0x00042402` | `0x30A01038` |
| `0x05AA4` | `0x0680` | `0x00042402` | `0x30A01058` |
| `0x06124` | `0x0024` | `0x00042400` | `0x30A01098` |
| `0x06148` | `0x0200` | `0x00042402` | `0x30A01088` |
| `0x06348` | `0x0230` | `0x00042501` | `0x30A01068` |
| `0x06578` | `0x0AD0` | `0x00042402` | `0x30A01048` |
| `0x07048` | `0x035C` | `0x00042400` | `0x30A01078` |
| `0x073A4` | `0x0008` | `0x00010000` | `0x30A01028` |
| `0x073AC` | `0x0010` | `0x00010000` | `0x30A01018` |

The chain terminates exactly at `0x073BC`. Flags are **undecoded**; they
likely encode element type/count.

### Element-size table — file `0x43A8`, rows of `[next, tag, total, chunk]`

Every total is an exact multiple of its chunk, so **the file states its own
record strides**:

| tag | total | chunk (stride) | records |
|---|---|---|---|
| `0x30A01038` | `0x1020` | `0x0408` | **4** |
| `0x30A01058` | `0x0680` | `0x01A0` | **4** |
| `0x30A01098` | `0x0024` | `0x0024` | 1 |
| `0x30A01088` | `0x0200` | `0x0080` | **4** |
| `0x30A01068` | `0x0230` | `0x008C` | **4** |
| `0x30A01048` | `0x0AD0` | `0x02B4` | **4** |
| `0x30A01078` | `0x035C` | `0x035C` | 1 |

Entropy is uniformly low-to-mid (no window above 6 bits/byte): **no code and
no compression** in this block.

---

## 3. Records are per-vehicle-variant

The 4 records in each multi-record table are **vehicle variants**, not
per-feature configurations.

Evidence: within `0x30A01038` only fields `+0x1C0`/`+0x1C4` differ between
records — the breakpoint axes at `+0x208`…`+0x214` and the constant at `+0x3D8`
are byte-identical in every record of every firmware generation. The same
pattern holds in tags `0x30A01048`/`0x30A01058`, where only `+0x000` and
`+0x010` move.

Record uniqueness patterns: `[0,1,2,3]` for tags `1038`/`1058`/`1048`,
`[0,1,1,1]` for `1068`, `[0,0,0,0]` for `1088`.

**This vehicle runs variant record 2** — proven because record 2's stored
64.60 km/h reproduced the measured 64.56 km/h engagement, and no other record
does.

> **What selects the record at runtime is UNKNOWN.** Nothing in the calibration
> encodes a selector, so it must be application-side — plausibly derived from a
> configuration DID (vehicle line / market). This remains open.

---

## 4. How the firmware reaches the data — by TAG, never by address

Proven from disassembly:

```
ba41c:  d4 c0 30 a0   seth r4,#0x30a0
ba420:  84 e4 10 38   or3  r4,r4,#0x1038      <- tag 0x30A01038
ba428:  fe ff fc bf   bl   0xb9724            <- resolver, returns a pointer
```

All seven tags are built this way and passed in `r4` to the resolver at
`0x0B9724` (tags `0x30A01018`/`0x30A01028` go to a second resolver at
`0x05C168`). At `0x05BEE8` the code range-checks a tag against `0x30A01099`,
validating membership of the `0x30A010xx` family.

Callers then index the returned pointer with `ld rX,@(disp,rBase)`.

**Consequence:** a search for absolute calibration addresses as instruction
literals returns **zero hits** — correctly. An exhaustive scan of all 15 330
`LD24` immediates and all 241 `SETH`+`OR3` constant pairs in verified code
regions found no reference to any calibration address or table base. That
negative is a *finding*, not a failure.

The records are also **copied into RAM**: a gate at `0x0C13FC` reads the same
`+0x1C0`/`+0x1C4` offsets from base `0x0082DC6C`, established by
`ld24 r8,0x82dc6c`.

---

## 5. Known field semantics

### Speed gate — `[arm @ +0x000, band @ +0x010]`, km/h

Used by tags `0x30A01048`, `0x30A01058` (LKA) and `0x30A01068` (LCA).
**Drop-out speed is computed as `arm − band`; it is not stored.** That is why
no disengage constant exists anywhere in the block — an exhaustive scan for
75 km/h and 20.83 m/s returns empty.

### Speed gate — m/s copy, tag `0x30A01038` `+0x1C0`/`+0x1C4`

`+0x1C0` = drop, `+0x1C4` = arm, in m/s. Followed by the invariant constants
`68.0` and `70.0` at `+0x1C8`/`+0x1CC`. **Not the operative copy** (see
`IPMA_speed_gates.md` §4).

### Lateral-control gain schedule — tag `0x30A01038` `+0x208` (X) / `+0x258` (Y)

10 breakpoints, identical in all records and all generations:

```
X m/s : 0.0   16.7   19.4   22.2   25.0   27.8   31.3   36.1   41.7   70.0
X km/h: 0.0   60.1   69.8   79.9   90.0  100.1  112.7  130.0  150.1  252.0
Y gain: 0.0   0.00025 0.00075 0.00125 0.00175 0.0025 0.004 0.01 0.015 1.0
```

An 8-point companion Y array sits at `+0x2A0`.

**Safety-relevant:** the axis starts at 0.0 m/s with gain 0.0. Lowering a
speed gate therefore stays *inside* the calibrated range and the schedule
predicts **less** steering authority at lower speed — not an extrapolation into
undefined behaviour.

This is a prediction from the calibration, **not a measurement**: the only
torque signal on the bus (`TorsionBarTorque`) reports *driver input*, not EPS
assist output, so the authority actually applied was never observed.

### Geometry axes

Tags `0x30A01058` and `0x30A01048` carry short lateral-offset / curvature axes
repeated identically in all records — e.g. `2.6, 2.8, 3.0, 3.5, 4.0` (lane
width in metres) and `0.2, 0.3, 0.4, 0.5, 0.6`.

---

## 6. What remains undecoded

* Region flags (`0x00042402`, `0x00042501`, `0x00042400`, `0x00010001`).
* The largest region, tag `0x00000A00` (`0x012C`..`0x1A84`, `0x1958` bytes) —
  it has **no chunk entry** in the size table, so it could not be decomposed
  into records. It holds many lone round scalars including the block's only
  `64.0` (file `0x0BC0`) and only `65.0` (file `0x1264`). This is the main
  unexamined area.
* The runtime variant selector.
* Field names — there is no A2L, no symbol table, no DID map. Every semantic
  label in this documentation is inferred from data shape plus on-vehicle
  behaviour, and is marked accordingly.
