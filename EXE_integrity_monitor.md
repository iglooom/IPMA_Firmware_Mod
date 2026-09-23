# IPMA Application (EXE) integrity — SOLVED (four layers; internal CRC-32C found via BM5T diff)

**A modified application (EXE) IS flashable.** There are FOUR integrity layers,
and the one that caused the "boots ~2 s then diag/CAN dies" failure was a hidden
**internal CRC-32C** word we were not repairing. It is now decoded, verified
reproducing the stock value on BOTH the CV4T and BM5T OEM images, and repaired by
`work/patch_handsoff.py`.

## The four layers (repair in this order)

| # | layer | algorithm | location | tool |
|---|---|---|---|---|
| 0 | **internal CRC-32C "tail"** | `~CRC32C(block[0:0x224] + block[0x228:end-7])`, poly `0x82F63B78`, init `0xFFFFFFFF`, no final XOR, then bitwise-NOT | word at `BootNfo.end - 7`, wrapped in `0xB0F0FFFF` sentinels (CV4T file `0xDCB00`) | patch_handsoff.py |
| 1 | BootNfo CRC-32 | `zlib.crc32(block)` with the 4 bytes at `0x224` skipped | block `+0x224` | patch_handsoff.py |
| 2 | block CRC-16/CCITT | over block payload | container | vbftool |
| 3 | header file_checksum | `zlib.crc32` over blocks | header | vbftool |

Order matters: layer 0 covers content up to itself but NOT the `0x224` slot; layer 1
covers the whole block INCLUDING the layer-0 word. So write layer 0 first, then 1.

Verified on the shipped `CV4T-14F397-AF_HANDSOFF.VBF` (all four independently
recompute clean; diff vs OEM = the 2 code edits + layer-0 word + layer-1 word only):

```
tail CRC-32C: stored=CF1AF0A3 calc=CF1AF0A3 OK   (@file 0xDCB00)
BootNfo CRC : stored=1E83AC98 calc=1E83AC98 OK   (@file 0x224)
block CRC-16: stored=77A7     calc=77A7     OK
file CRC-32 : 56ABC60B in header                 OK
code edits  : 0x356F0=6300f000, 0x35800=6300f000 present
```

## How it was found (the method that worked)

Purely-static hunting for the missing layer failed for a long time — the value is
NOT a whole-block self-CRC (exhaustive 4-table × init × xorout × skip/zero sweep
found only the `0x224` word). The break came from a **second known-good image**:
the user flashed **BM5T-14F397-AG standalone and it ran**, proving the integrity
is fully self-contained in the VBF (killing the external/NVM/RAM-value theories).

Diffing the CV4T and BM5T app blocks then exposed a build-specific word at the very
end, bracketed by `0xB0F0FFFF` sentinels, differing where everything around it was
identical. Testing `~CRC32C` over `[0:0x224)+[0x228:end-7)` reproduced BOTH stored
words exactly — Rule 0 on two independent images, which is what promotes it from
"plausible" to proven.

The `flash_oem.log` / `flash_mod_bad.log` comparison had already established the
crash is 100 % a function of the flashed app-block bytes (OEM reflash works; the
bad flash differed by only the 2 code edits + the layer-1 word; download is
byte-pure; `31 01 0304` returns success in both — no NVM step).

## Runtime monitor (mechanism, for reference)

Continuous background monitor (tick `0x91194`, compare `0x91410`/`0x91424`) uses
two engines: zlib CRC-32 (`0xb5d04`, table `0xf058c`) and CRC-32C (`0xb5d14`,
table `0xf018c`, poly `0x82F63B78`). Mode A reads the expected word at
`*(desc.end - 7)` and compares it to `~accumulator`. A wrong value faults a couple
of seconds after boot (not at boot), which is the observed symptom. The layer-0
recipe above is exactly what that path recomputes.

## Status: VALIDATED ON CAR ✓

`CV4T-14F397-AF_HANDSOFF.VBF` (all four integrity layers correct) was flashed to
the vehicle: **the module boots, stays up, and sets NO DTCs.** The internal
CRC-32C at `end-7` was the sole remaining blocker; with all four layers repaired
the modified application runs cleanly. The hands-off mod is complete.

Recovery is unchanged (OEM reflash of `CV4T-14F397-AF.VBF` in the ~2 s window).

---

## (Historical) investigation notes below — superseded by the SOLVED summary above

## NEW LEAD (differential vs BM5T): a sentinel-wrapped tail checksum record

The user flashed **BM5T-14F397-AG standalone and it works**, proving the integrity
is FULLY SELF-CONTAINED in the app VBF (no external/NVM/RAM-only value — that whole
theory is dead). BM5T is therefore a second known-good image for differential
analysis.

Comparing CV4T and BM5T app blocks reveals, at the very end of each block, an
identical descriptor with **one build-specific word wrapped in `B0F0FFFF`
sentinels**:

```
... 00008A0C 00002283 00000000 00000004 00000001  B0F0FFFF  <WORD>  B0F0FFFF
CV4T:  WORD = 0xDFCDACD9  at file 0xDCB00 (mem 0xFCB00, = block end - 7)
BM5T:  WORD = 0xCD2F468A  at file 0xDAFD8 (mem 0xFAFD8, = block end - 7)
```

The five preceding fields (`8A0C, 2283, 0, 4, 1`) are **identical in both builds**;
only the sentinel-wrapped WORD differs. This is the missing second integrity value
— a per-build checksum at `end-7`, which our HANDSOFF/CRCTEST builds never touch.
It is the `*(end-7)` operand that the monitor's Mode-A compare (`0x91424:
addi r2,#-7`) reads, which earlier analysis had noted but not connected.

### Still not cracked: the WORD's algorithm

Extensively tested against both images, NO match:

* contiguous CRC over `[start..end)` for every start `< 0x2000` and ALL ends,
  4 poly tables (zlib `0xEDB88320`, crc32c `0x82F63B78`, `0xE1351B80`,
  `0x04C11DB7`), init `{0,FFFFFFFF}`, xorout `{0,FFFFFFFF}`, output as-is AND
  byte-swapped — only coincidental hits at meaningless `(start,end)`;
* CRC over `[S..record_start)` / `[S..end-7)` skipping the word;
* sum32 / ~sum32 / -sum32 over block-minus-word.

Because it resists every contiguous-CRC form, the WORD is almost certainly a
**non-contiguous checksum** (the documented Ford pattern: a code CRC built to skip
the separately-flashed calibration/DSP holes) or a custom accumulator. Per the
skill's escalation ladder, STOP brute-forcing and read the routine:

* The compare is Mode A at `0x91410`/`0x91424` (`ld r2,@(4,desc); addi r2,#-7;
  ld r0,@r2; beq`). Decode which region/stride it feeds the CRC engine (`0xb5d04`
  zlib / `0xb5d14` crc32c) and whether it walks a skip-list.
* The `8A0C`/`2283` descriptor fields likely encode the covered layout (count /
  length / gap). Decode them from the routine that consumes this record.
* Best: dump the CRC accumulator/expected at runtime, or single-step the monitor.

Once the recipe reproduces BOTH stored words (Rule 0 on CV4T **and** BM5T), add it
to `patch_handsoff.py` as a 4th repair layer and rebuild.

## Correction to the slice-0 A/B test

The earlier slice-0 probe (`CV4T-14F397-AF_CRCTEST_S0.VBF`, flipped `0x201A0`)
crashing is **NOT clean evidence of whole-block coverage**: `0x201A0` is the top
byte of an all-`0xFF` word in the interrupt-vector-table tail, and flipping it to
`0x00` turns `0xFFFFFFFF` into `0x00FFFFFF` — a plausible bad vector address that
could fault functionally, independent of any checksum. Only the original CRCTEST
at `0x0E1A50` (deep in a data-pool `0xFF` run, no code/vector refs) is a clean
integrity probe. Do not draw region-coverage conclusions from the slice-0 result.

---

## What is actually still unresolved (open)  — earlier notes, see NEW LEAD above

1. **A second CRC engine.** There are two CRC-32 tables and both are used:
   * `0xf058c` — standard zlib CRC-32 (poly `0xEDB88320`), engine entry `0xb5d04`.
   * `0xf018c` — **CRC-32C / Castagnoli (poly `0x82F63B78`)**, engine entry
     `0xb5d14`. The monitor's per-tick validator `0x914c0` calls the **CRC-32C**
     engine over a table based at RAM `0x821ad8` (`ld24 r0,0x821ad8; add r8,r0*4`).
   The whole-block zlib CRC I verified is only ONE of the checks; the CRC-32C
   path over the descriptor/region structures was never reproduced or repaired.
2. **The monitor iterates a MULTI-entry region set**, indexed by a count byte at
   `0x821b15` and a 12-byte-stride cursor at `0x821ac4`, both seeded from `.data`
   at boot. The exact region table (how many entries, their bounds, and where
   each entry's expected CRC is stored) was NOT pinned — a static register trace
   kept producing whole-block-only answers that the vehicle disproves.
3. **A likely finalize/NVM-written expected value.** The OEM flow runs routine
   `31 01 0304` after download (see `FLASH_RESULTS.md`); an app-only 3rd-party
   flash that skips it may leave a monitored expected-CRC (in a data/NVM region
   the app flash does not rewrite) stale — which would boot-then-fault exactly as
   observed.

## What the flash logs proved (flash_oem.log vs flash_mod_bad.log)

Both logs were captured with the user's own flasher (sends VBF bytes only, does
nothing about CRCs). The comparison is now airtight:

* **OEM reflash with the same flasher WORKS** (module runs). MOD crashes ~2 s in.
* The 221 `36` transferData chunks **reassemble byte-for-byte to the app block**;
  there is no separate signature/trailer block, and the last chunk `36DD` is just
  the final data chunk (verified: reassembled payload == OEM block exactly).
* MOD download differs from OEM by **exactly 8 bytes**: the 2 code edits
  (`0x556F0`, `0x55800`) + the recomputed BootNfo CRC-32 at `0x20224`. Nothing else.
* `31 01 0304` (finalise) returns the **same `71 01 03 04 10 02`** in BOTH flashes —
  it does NOT reject the MOD at flash time. No WriteDataByIdentifier, no NVM step.

**Therefore the rejecter is a runtime check that is 100 % a function of those 8
changed app-block bytes** — not the flash procedure, not an external/NVM value.
There is a second integrity value the module recomputes at runtime that our patch
leaves inconsistent, and it must live inside the app block (or be derived from it).

The single-inert-byte control (`CV4T-14F397-AF_CRCTEST.VBF`, flips only the unused
padding byte `0x0E1A50` + repairs the same 3 layers) **also crashes** — proving
the extra check is a pure content checksum, independent of what/where the byte is,
covering at least the region that includes `0x0E1A50`.

## What is still unresolved (the actual blocker)

We know a second content checksum exists but have NOT located its algorithm,
covered region, or storage offset. On-vehicle A/B proved it effectively covers
the WHOLE block: an inert-byte flip at the START (slice 0, `0x201A0`, vector-tail
padding) AND at the END (`0x0E1A50`) BOTH crash the same way, each with all three
known layers repaired. So it is a whole-block (or near-whole-block) check whose
expected value we do not reproduce.

Ruled OUT by static search on the OEM image (all negative):

* second whole-block self-CRC word at ANY offset — single-slot AND twin-slot
  (both `0x224` + a second word skipped), for zlib CRC-32 AND CRC-32C, in
  skip/zeroed conventions (fast CRC-combine C sweep, Rule-0 re-found `0x224`);
* the value stored in the DSP (`0x200000`) or calibration (`0x3000`) parts
  (cross-part checksum) — only `0x224` holds the whole-block CRC, in the app;
* CRC residue / self-check-to-constant (zlib `0x2144DF1C`, crc32c `0x48674BC7`);
* byte-swapped (word-wise) stream CRC, both polys, all init/xorout;
* sum32/sum16/sum8/xor32 (BE+LE) whole-block and any prefix reaching a round
  constant; two's-complement balance word;
* all FOUR CRC tables present in the image tried whole-block: `0xf058c` zlib,
  `0xf018c` CRC-32C, `0xf9f0c` zlib (dup), `0xfa70c` **poly `0xE1351B80`**
  (non-standard) — none reproduce a stored word. NB the `0xf9f0c`/`0xfa70c`
  tables have NO code xref (no ld24, no matching seth/or3), so they look like
  unused library data, not the active check.

The active monitor uses two engines (zlib `0xb5d04`, CRC-32C `0xb5d14`); its
per-tick validator `0x914c0` runs CRC-32C over a RAM table at `0x821ad8` seeded
from a `.data` ROM-shadow not yet pinned. The expected value it compares against
is almost certainly computed from a RAM working copy (not a flash literal), which
is why an image-only static hunt for a stored word keeps coming up empty.

## Honest status

Purely-static identification has been exhausted at the level a scan can reach
reliably. The remaining viable paths all need more than the app image alone:

1. **Dynamic read.** Dump the module's RAM around `0x821ac0..0x821b20` (the
   monitor's live descriptor table + accumulators) over the SBL read path or a
   debugger, right after boot, on an OEM-good module. That gives the exact region
   bounds and the expected value directly — no guessing.
2. **Trace the `.data` initialiser in the SBL/crt0** to find where `0x821ad8`'s
   contents are copied from in flash (the region-descriptor source), then decode
   the compare in `0x91410`/`0x914c0` against that concrete structure.
3. **Accept the app-code mod is not currently flashable** and keep the working,
   validated calibration mods (LKA/LCA speed on CV4T and F1FT), which are in a
   different part the monitor does not gate.

Do NOT flash another modified EXE hoping to have guessed the layer; every such
attempt is a ~2 s-recovery cycle with no new information unless it is a designed
A/B probe.

---

## Deterministic next steps (superseded — see above)

---

## (RETRACTED) earlier "decoded and closed" analysis — kept for provenance

The section below was written before the on-vehicle failure was known. Its
mechanical facts about the monitor (addresses, the zlib engine, the BootNfo
triple) are correct, but its **conclusion that repairing the one BootNfo CRC is
sufficient is FALSE** — see the correction above.

**Result: the "third layer" is not a separate checksum. The background runtime
monitor recomputes the SAME BootNfo CRC-32 that already sits in the block header.
Repairing the BootNfo word (which `patch_handsoff.py` already does) satisfies the
monitor. An application code edit is therefore flashable after the normal three
container/BootNfo layers — no extra unknown to crack.**

This supersedes the earlier draft of this document, which hypothesised an
unknown non-contiguous multi-region table and said "no patch is safe". That was
a conservative guess made before the descriptor was traced; the guess was wrong.
No EXE flash was ever attempted on the vehicle (see `FLASH_RESULTS.md` — only the
calibration was flashed and road-validated), so nothing was ever bricked; the
brick was an anticipated risk, now retired.

Re-derive everything here with `work/verify_exe_monitor.py` (Rule-0 validated on
three OEM builds).

## The monitor (proven from code)

Background, chunked, resumable integrity monitor in the Application block
(`CV4T-14F397-AF`, load `0x20000`):

* **Tick/driver:** `0x91194` (calls validator `0x914c0`, then walks one region step).
* **Region walk + compare:** `0x91310..0x9144c`.
* **CRC-32 engine:** entry `0xb5d04`/core `0xb5d24`, table at mem `0xf058c`
  (256×u32 BE). Standard zlib polynomial (`T[1]=0x77073096`, `T[128]=0xedb88320`
  → reflected CRC-32/ISO-HDLC). Region-with-skip helper `0xb5e00` CRCs
  `[start..end)` while **skipping the 4-byte stored-CRC slot** (`add3 r0,r7,#4`).
  (A CRC-16 engine `0xb5dd8`, table `0xf098c`, poly 0x1021 reflected, also exists
  for other uses.)
* **Accumulator** RAM `0x821ac8`; **descriptor cursor** `0x821ac4`; **count**
  `0x821b15`; **chunk remaining** `0x821acc`.

### What the cursor actually points at — the key finding

The descriptor cursor `0x821ac4` does **not** point at a bespoke region table. It
points at the **BootNfo descriptor triple** inside each flashable block's header.
The monitor resolves the descriptor for a block via `0x25a20` → `0x259a8`
(index → memory-permission range) → `0x25f78`/`0x25ba0` (scan that range for a
record with magic `0xAA5AA555`), then reads, at descriptor `+0x1C/+0x20/+0x24`:

```
+0x1C  start   (block load address)
+0x20  end     (last byte address, inclusive)
+0x24  stored CRC-32
```

For the application block this triple lives at file `0x21C`:

```
00020000 000fcb07 b8b8ec7a      = [start=0x20000][end=0xFCB07][crc=0xB8B8EC7A]
```

which is exactly the BootNfo header's own `+0x1C/+0x20/+0x24` (BootNfo base
`0x200`). The earlier "12-byte record with relocatable start" reading was a
misinterpretation of this same BootNfo triple.

### Compare semantics (exact)

At region completion (`0x91410`):

```
region   = block[start .. end]                 (== the whole block)
accum    = zlib_core(region, seed 0xFFFFFFFF, SKIP the 4 CRC bytes, NO final XOR)
expected = stored CRC at descriptor +0x24 (equivalently *(end-7) in the alt mode)
pass iff  expected == ~accum   ==   zlib.crc32(region_with_crc_slot_skipped)
```

`not r1,r1` at `0x91420`/`0x9143c` converts the no-final-XOR accumulator to the
conventional `zlib.crc32`. Net: **pass iff `stored == zlib.crc32(region, skip-4
@ +0x224)`** — byte-for-byte the BootNfo CRC-32 recipe. Mismatch sets `r9|=2` →
fault path `0xb7fe0` (fault-code imm #24/#37/#38), report `0x3d4a4`. It is a
**continuous** monitor, so a wrong value would fault while driving, not just at
boot — which is why getting it right matters. Getting it right just means
repairing the BootNfo word.

## Proof (Rule 0 — reproduce the STOCK word, uniquely, on multiple builds)

`work/verify_exe_monitor.py` runs the monitor's exact computation and reproduces
each **unmodified OEM** stored CRC:

```
CV4T-14F397-AF  [0x020000..0x0FCB07]  stored=0xB8B8EC7A  calc=0xB8B8EC7A  MATCH
F1FT-14F397-AG  [0x010000..0x0F4E37]  stored=0x0CBC60C1  calc=0x0CBC60C1  MATCH
BM5T-14F397-AG  [0x020000..0x0FAFDF]  stored=0xF0F0674F  calc=0xF0F0674F  MATCH
```

Three independent builds reproduced by one (algorithm, span, skip) is ~2^-96
against coincidence. The earlier "0 self-consistent regions" negative came from
sweeping for a *separate* table and for `desc[2]`/`end-7` conventions on the
whole image; the true descriptor is the BootNfo triple with the skip-4 slot, and
it closes cleanly.

## Consequence for patching the application

The three layers to repair for an EXE code edit, in order:

1. **BootNfo CRC-32** at block `+0x224` (skip-4 zlib). **This is also the runtime
   monitor's number** — one repair covers both the boot check and the continuous
   monitor.
2. block CRC-16/CCITT-FALSE (container, vbftool).
3. header file_checksum CRC-32 (container, vbftool).

There is **no fourth/unknown layer**. `patch_handsoff.py` already repairs all
three and its output passes the monitor:

```
CV4T-14F397-AF_HANDSOFF.VBF  [0x020000..0x0FCB07]
   stored=0xC472909A  monitor_calc=0xC472909A  MATCH   (monitor ACCEPTS)
```

## Patch discipline

* Always run `work/verify_exe_monitor.py <build.vbf>` on any modified EXE and
  require MATCH before flashing — it is the monitor's own computation.
* Keep edits inside `[start..end]`; the CRC covers the whole block, so any code
  change is caught and repaired by recomputing the one BootNfo word.
* On-target validation still needs a soak/run-cycle (the monitor is continuous),
  but there is no remaining static unknown blocking the flash.

## Verified facts inventory

| item | value | status |
|---|---|---|
| monitor tick | `0x91194` | proven |
| CRC-32 table | mem `0xf058c`, zlib poly | proven |
| region-skip helper | `0xb5e00` (skip 4-byte CRC slot) | proven |
| compare | `stored == zlib.crc32(region, skip-4)` | proven |
| descriptor source | BootNfo triple at desc `+0x1C/+0x20/+0x24` | **proven (was OPEN)** |
| region composition | whole block `[start..end]`, no hidden table | **CLOSED** |
| fault path | `0xb7fe0`, report `0x3d4a4` | proven |
| reproduced on OEM builds | CV4T + F1FT + BM5T | proven |
