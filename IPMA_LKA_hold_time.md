# IPMA LKA intervention hold time — the "~3.7 s cap"

**The 3.7 s limit on LKA interventions is a calibration constant in the IPMA,
in seconds, and it is directly patchable.** It is *not* a hard-coded firmware
timer and not a PSCM behaviour.

Applies to **CV4T-14F398-AF** (release 4.27.0, CSF265, the vehicle under study).
F1FT is deliberately out of scope here — see §7.

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

## 3. The hard ceiling: 65.535 s

`round(seconds * 1000)` is stored with `sth` into a **u16**. Anything above
**65.535 s** wraps and silently produces a *shorter* hold than OEM. The tool
refuses such values rather than emitting a wrapping image.

---

## 4. How to patch

```bash
cd /home/gl/Projects/ford/IPMA/Research
python3 work/patch_thresholds.py --selftest                  # 40+ checks

# hold time alone
python3 work/patch_thresholds.py --lka-hold 12 --dry-run

# together with the speed gates (the usual combination)
python3 work/patch_thresholds.py --lka-arm 40 --lca-arm 45 --lka-hold 12 \
        -o CV4T-14F398-AF_LKA40_LCA45_HOLD12.VBF
```

All four records are written, because the runtime variant selector is still
unknown (the same open question as the speed gates). Integrity is repaired in
the required order: BootNfo CRC-32 → block CRC-16 → file CRC-32.

### Verification of the built artifact

```
vbftool verify   -> OK (1 blocks)
vbftool diff     -> 12 clusters, 36 bytes, ALL accounted:
   0x003024  BootNfo CRC-32
   0x005C1C / 0x005DBC / 0x005F5C / 0x0060FC   406ccccd -> 41400000
                                               (3.7f -> 12.0f)   <- the hold
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

---

## 7. F1FT

Out of scope by decision — CV4T first. The F1FT calibration is structurally
different (flat 28-row index, per-region `~crc32`) and the corresponding field
must be relocated within its `0x624` variant regions before the same edit can be
made. `F1FT-14F398-AG` region 0 shows `+0x1F4 = 3.9`, aligning with the CV4T
`30A01048 +0x174 = 3.9` sibling rather than with `tag58 +0x178 = 3.7`, so the
offset needs deriving, not assuming.
