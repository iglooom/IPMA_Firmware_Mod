# IPMA LKA intervention hold time — the "~3.7 s cap"

**The 3.7 s limit on LKA interventions is a calibration constant in the IPMA,
in seconds, and it is directly patchable.** It is *not* a hard-coded firmware
timer and not a PSCM behaviour.

Applies to **CV4T-14F398-AF** (release 4.27.0, CSF265) and, since the port,
**F1FT-14F398-AG** (release 4.93.06, CSF2F0) — see §7 for the F1FT offsets.

```
Field     tag 30A01058  +0x178   big-endian float32, SECONDS
OEM       3.7
Records   all four hold 3.7 on CV4T  (BM5T holds 3.5/3.5/3.7/3.7 -> per-variant knob)
Sites     file 0x2C1C / 0x2DBC / 0x2F5C / 0x30FC
          mem  0x05C1C / 0x05DBC / 0x05F5C / 0x060FC
Ceiling   65.535 s  (marshalled as round(s*1000) into a u16)
```

---

## 1. Why this field and not another

Only **four** float32 words in the whole 17 KB calibration lie anywhere in
3.60–3.80, and all four are this one field. There is no other candidate.

| Check | Result |
|---|---|
| Exhaustive scan, all 4362 aligned words, value ∈ [3.60, 3.80] | 4 hits, all `tag58 +0x178` |
| Value in **seconds** matches the measured cap | stored 3.7 vs measured **3.70–3.72 s** |
| Present in the LCA region `30A01068`? | **No** — and LCA is uncapped in practice (mean 7.16 s, max 57.4 s) |
| Varies per variant in another generation? | **Yes** — BM5T records hold `3.5, 3.5, 3.7, 3.7` |

The LCA negative is the strongest discriminator: the drive data shows LKA
capped near 3.7 s while LCA ran to 57.4 s. A constant that appears in the LKA
structure and is absent from the LCA structure is exactly the asymmetry the
road data demands.

---

## 2. The full runtime chain (traced in the application image)

The calibration is float seconds; the control code counts integer ticks. Three
stages, all located:

```
  CALIBRATION        tag 30A01058 +0x178 = 3.7   (float32 s)
        |
        |  app 0x0542D0   marshaller
        |     ld   r4,@(376,r9)          ; +0x178 from the tag-58 RAM copy
        |     ld   r3,@(28,sp)           ; 1000.0f   (seth 0x447A)
        |     <FPU multiply>
        |     bl   0xDE924               ; float -> int
        |     ld24 r3,0x804948
        |     sth  r0,@r3                ; u16 MILLISECONDS   <-- the ceiling
        v
  PARAM BLOCK        0x804948 = 3700 ms
        |
        |  app 0x059080   arm the timer (on entry to the intervention state)
        |     ld24 r1,0x804948
        |     lduh r4,@r1                ; 3700
        |     and3 r0,r9,#0xffff         ; task period, ms
        |     div  r4,r0                 ; ticks = ms / period
        |     sth  r4,@(204,r10)
        v
  COUNTDOWN          (204,r10)
           app 0x058F20   once per task cycle, while intervening
             lduh r11,@(204,r10)
             beqz r11,0x58F34            ; expired -> fall through to exit
             lduh r0,@r1 -> addi r0,#-1
             sth  r0,@r1
```

The state machine that owns it is `0x058D1C`, dispatching on the state byte at
`(68,r8)`; states 1 and 2 (the two intervention directions) branch to the
`0x58F20` countdown. When it reaches zero the module leaves the intervening
state and loads the **re-arm / suppression** hold from the sibling field.

### Why the units are certainly seconds

The marshaller's `×1000` is explicit in the instruction stream, and the
neighbouring `+0x174 = 120.0` goes through the same `×1000` into a **32-bit**
store (120 000 — too large for the u16 path, which is why that one is `st` not
`sth`). Stored 3.7 → 3700 ms → measured 3.70–3.72 s closes the loop end to end.

### The sibling field

```
tag 30A01058 +0x184 = 0.5 s  -> 0x80494E -> counter (206,r10), armed at 0x058E94
```
This is the post-intervention suppression hold — how long the module refuses to
re-trigger. Exposed as `--lka-rearm`. Lowering it shortens the gap between
consecutive interventions; it does **not** extend a single intervention.

---

## 3. Two ceilings — and the low one is the one that bites

### 3a. Per-record range bound (the binding constraint)

Each hold field has a **stored upper bound** next to it, and the module enforces
it at runtime. Exceeding it produces a file that passes *every* checksum layer
and still faults the IPMA.

```
CV4T   bound at hold+0x1C     all four records = 6.0 s
F1FT   bound at region+0x4CC  regions 2-3 = 6.0 s ; regions 4-12 = 65.0 s
```

**This is what broke `F1FT-14F398-AG_LKA40_LCA45_HOLD12.VBF` on the vehicle.**
Both patchers now refuse an out-of-bound `--lka-hold` and offer `--clamp-hold`
to write `min(requested, bound)` per record. `verify()` reports violations as a
fourth layer.

Evidence it is a bound (not proven by tracing the consuming code):

| Check | Result |
|---|---|
| Structural mirror | F1FT `+0x4C8/+0x4CC/+0x4D0` = `(4, 6, 30)` == CV4T `hold+0x18/+0x1C/+0x20` |
| Tracks the knob | OEM hold 3.7 -> companion 6.0; OEM hold 6.0 -> companion 65.0 |
| Cross-generation invariant | CV4T, BM5T, BK2T: **every** hold-like record satisfies `hold <= companion`, no OEM exception |
| Discriminates the two builds | speed-gate-only build (no bounded field touched) flashed and ran fine; the 12 s build faulted |

### 3b. The u16 marshalling ceiling: 65.535 s

`round(seconds * 1000)` is stored with `sth` into a **u16**. Anything above
**65.535 s** wraps and silently produces a *shorter* hold than OEM. The tool
refuses such values rather than emitting a wrapping image. In practice 3a binds
first almost everywhere.

---

## 4. How to patch

```bash
cd /home/gl/Projects/ford/IPMA/Research
python3 work/patch_thresholds.py --selftest                  # 40+ checks

# hold time alone
python3 work/patch_thresholds.py --lka-hold 12 --dry-run

# together with the speed gates (the usual combination)
python3 work/patch_thresholds.py --lka-arm 40 --lca-arm 45 --lka-hold 12 \
        --clamp-hold -o CV4T-14F398-AF_LKA40_LCA45_HOLD12.VBF
# NOTE: on CV4T all four records are bounded at 6.0 s, so this writes 6.0,
# NOT 12.0. Without --clamp-hold the tool refuses (see 3a).
```

All four records are written, because the runtime variant selector is still
unknown (the same open question as the speed gates). Integrity is repaired in
the required order: BootNfo CRC-32 → block CRC-16 → file CRC-32.

### Verification of the built artifact

```
vbftool verify   -> OK (1 blocks)
vbftool diff     -> 12 clusters, 32 bytes, ALL accounted:
   0x003024  BootNfo CRC-32
   0x005C1C / 0x005DBC / 0x005F5C / 0x0060FC   406ccccd -> 40c00000
                                               (3.7f -> 6.0f, clamped)
   remaining clusters are the speed-gate edits
```

Zero unexplained bytes.

---

## 5. What this does and does not change

* It extends how long **one continuous LKA intervention** may last.
* It does **not** change *why* an intervention ends. Interventions also end at
  the speed gate, on lane loss, and on driver override — all unaffected.
* It does **not** touch LCA, which has no such constant and was never capped.
* Steering authority per unit time is unchanged; only the duration limit moves.

Consequently, on a road where interventions were ending for some *other*
reason, raising this value will change nothing. The pre-patch evidence for the
cap being the binding constraint is the 3.70–3.72 s clustering with near-zero
spread across 53 of 69 episodes while the PSCM still reported
`LaActAvail=3, LaActDeny=0`.

---

## 6. Safety

Ford chose 3.7 s as a hands-on lane-keeping design point; a longer hold moves
further from the validated envelope and closer to sustained hands-off steering,
which this module's LKA path is not designed to supervise. **12 s is suggested
as a first step, not 60.** The system stays fully overridable and the PSCM's own
limits are untouched. Treat as an evaluation configuration.

Reverting is a single flash of the untouched `CV4T-14F398-AF.VBF`.

**Not yet road-validated.** The static chain is proven; the effect on measured
episode duration must be confirmed with `la_monitor.py` + `analyse_drive.py`
exactly as the speed-gate change was.

### Flash history — one known failure

| Build | Result |
|---|---|
| `F1FT-…_LKA40_LCA45.VBF` (gates only) | flashed, runs fine |
| `F1FT-…_LKA40_LCA45_HOLD12.VBF` (flat 12.0 s) | **faulted inside the IPMA** — violated the `+0x4CC` bound in regions 2/3 |
| same, rebuilt with `--clamp-hold` | built and verified clean; **not yet flashed** |

The failing build passed `vbftool verify`, all 30 region hashes and the block
and file CRCs. Container validity is not sufficient — check the bounds.

**Suggested positive control before trusting the bound theory.** Flash a build
with `--lka-hold 6 --clamp-hold` (inside every region's bound, so it writes 6.0
everywhere). If that runs clean where the flat 12 s build faulted, the bound is
confirmed as the mechanism. Until then it rests on structural mirroring and the
cross-generation invariant, not on a disassembly of the consuming code.

---

## 7. F1FT — ported

The F1FT calibration (`F1FT-14F398-AG`, 4.93.06, CSF2F0) is structurally
different — flat 28-row index, per-region `~crc32`, load `0x902000` — but the
hold field ports cleanly because F1FT preserves the CV4T *record-internal*
layout. On CV4T the hold is `tag58 arm +0x178`; on F1FT the LKA gate lives in
each `0x624` variant region as sub-record **B** with its arm at region `+0x334`
(the copy that governs the engage transition — see `F1FT_speed_gates.md`), so:

```
Field       region +0x4AC   (= arm-B +0x334 + 0x178)   big-endian float32, SECONDS
Re-arm      region +0x4B8   (= +0x334 + 0x184)          OEM 1.0
Companion   region +0x4A8 = 120.0  (the CV4T +0x174 sibling — structural signature)
OEM         region0/1 hold 3.7 ; regions 2-10 hold 6.0
```

**Confirmation the offset is right, not assumed:**

* Whole-block scan for any float in `[3.60, 3.80]` returns exactly 4 hits — two
  in region0/region1 at `+0x4AC`, two more in the *un-indexed* pre-index
  records at block `+0x688`/`+0xCAC` (see below). All four are this field.
* The `120.0` companion sits at `+0x4A8` (hold − 4) in every region, mirroring
  CV4T's `+0x174` sibling exactly — a structural fingerprint a coincidence
  cannot reproduce.
* region0 (the live 64.6 variant) holds **3.7**, matching CV4T's live record.

The earlier note that region0 `+0x1F4 = 3.9` "aligns with `tag48 +0x174`" was
correct but pointed at the wrong sub-record: `+0x1F4` is **sub-record A**'s
`+0x174` sibling (A arm `+0x080` + `0x174`), holding 3.9/0.1 — a *different*
timer. The operative hold is B's, at `+0x4AC`.

### Variant table is 13 records; only 11 are hashed

The F1FT variant table is **13** records of stride `0x624`. The flat index is
**30 rows at block `0x74`** (an earlier note here said 28 rows at `0x8C` — that
was wrong and made the patcher skip rows 0/1 entirely; harmless only because
those two regions are also the ones it does not edit). Of the 13 variant
records the tool patches the **11** from block `+0xE24` on. The two un-indexed records at
bases `+0x1DC`/`+0x800` are the low-spec **59.6** km/h variants (bands 5.0/4.3
— the CV4T rec0/rec1 pair), *not* the live 64.6 variant this vehicle runs.
Following the speed-gate scope decision, the port patches only the **11 indexed
regions** and leaves the 2 un-indexed gap records untouched — which also keeps
every edit inside a `~crc32`-hashed region and preserves the `+0x18` safety
argument (nothing lands in the un-hashed `[0..0xE24)` metadata).

### Caveat on units/ceiling

The F1FT marshaller was **not** independently re-traced. The field location and
`seconds` semantics are established by the exact structural mirror of CV4T and
by region0's 3.7. The `65.535 s` u16 ceiling is inherited from the CV4T
`round(s*1000)` path and enforced by the tool; **12 s is far inside it
regardless**, so the port is safe even if F1FT's exact marshalling differs.
As with CV4T, confirm the effect on measured episode duration on the road.

### How to patch (F1FT)

```bash
cd /home/gl/Projects/ford/IPMA/Research
python3 work/patch_thresholds_f1ft.py --selftest

# hold together with the speed gates (the usual combination)
python3 work/patch_thresholds_f1ft.py --lka-arm 40 --lca-arm 45 --lka-hold 12 \
        --clamp-hold -o F1FT-14F398-AG_LKA40_LCA45_HOLD12.VBF
# regions 2-3 clamp to their 6.0 s bound; regions 4-12 take the full 12.0 s.
# The live 64.6 km/h variant is region 2 -> 6.0 s, not 12.
```

Built artifact `F1FT-14F398-AG_LKA40_LCA45_HOLD12.VBF` (rebuilt with
`--clamp-hold`): `vbftool verify` OK, **119 changed bytes fully accounted** —
value floats (22 LKA arm A+B, 11 LCA, 11 hold, 2 m/s) + 12 region hashes +
header CRC-32 + block CRC-16, zero unexplained; `+0x18` unchanged; no region
exceeds its `+0x4CC` bound. Reverting is a single flash of the untouched
`OEM/F1FT-14F398-AG.VBF`.
