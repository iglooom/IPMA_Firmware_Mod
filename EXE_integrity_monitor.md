# IPMA Application (EXE) integrity — SOLVED (four layers; internal CRC-32C found via BM5T diff)

**A modified IPMA application (EXE) IS flashable and will survive the runtime
integrity monitor.** There are FOUR integrity layers. The one that is easy to
miss — and whose omission causes the characteristic "boots ~2 s, then
diagnostics and CAN go dark" failure — is a hidden **internal CRC-32C** word.
It is decoded, verified reproducing the stock value on BOTH the CV4T and BM5T
OEM images, and implemented in `work/patch_exe_integrity.py`.

> **Scope.** This document covers the *integrity recipe* for the EXE part only.
> It is deliberately edit-agnostic: it tells you how to re-seal a modified
> application, not what to modify. It was originally written while chasing a
> hands-off escalation mod; that mod has been abandoned and removed (§7), but
> the integrity result is independent of it and stands on its own.

---

## 1. The four layers (repair in this order)

| # | layer | algorithm | location | tool |
|---|---|---|---|---|
| 0 | **internal CRC-32C "tail"** | `~CRC32C(block[0:0x224] + block[0x228:end-7])`, poly `0x82F63B78`, init `0xFFFFFFFF`, no final XOR, then bitwise-NOT | word at `BootNfo.end - 7`, wrapped in `0xB0F0FFFF` sentinels (CV4T file `0xDCB00`) | patch_exe_integrity.py |
| 1 | BootNfo CRC-32 | `zlib.crc32(block)` with the 4 bytes at `+0x224` skipped (removed from the stream, **not** zeroed) | block `+0x224` | patch_exe_integrity.py |
| 2 | block CRC-16/CCITT-FALSE | over block payload | container | vbftool |
| 3 | header file_checksum | `zlib.crc32` over data_start..EOF | header | vbftool |

Order matters: layer 0 covers content up to itself but NOT the `0x224` slot;
layer 1 then covers the whole block INCLUDING the layer-0 word. Write layer 0
first, then layer 1.

Layers 0 and 1 are the ones no off-the-shelf tool repairs — `vbftool` handles
only 2 and 3.

---

## 2. How to use it

```bash
cd /home/gl/Projects/ford/IPMA/Research
python3 work/patch_exe_integrity.py --selftest                  # 13 checks
python3 work/patch_exe_integrity.py --verify OEM/CV4T-14F397-AF.VBF
```

As a library, for any future EXE modification:

```python
from patch_exe_integrity import reseal, verify
out = reseal(raw, [("my edit", file_off, expected_word_be, new_word_be)])
assert not verify(out)
```

`reseal(raw, [])` on an intact file is **byte-exact identical to the input** —
that identity property is the strongest available proof the container writer is
correct, and the selftest asserts it.

The tool derives every layer location from the image (BootNfo descriptor scan,
`end-7`, sentinel validation) rather than hard-coding offsets, and it **refuses**
to re-seal an image whose stock words do not already reproduce, so it cannot
silently launder a corrupted input.

Selftest output on the OEM CV4T application:

```
BootNfo descriptor at block 0x200      BootNfo CRC slot at 0x224
tail word at file 0xDCB00              sentinels 0xB0F0FFFF both sides
BootNfo CRC-32 reproduces  0xB8B8EC7A
tail CRC-32C   reproduces  0xDFCDACD9
reseal([]) == input                    (byte-exact)
```

---

## 3. How layer 0 was found

Brute force failed. Exhaustive contiguous-CRC search over `[start..end)` for
every start `< 0x2000` and all ends, four polynomial tables (zlib `0xEDB88320`,
CRC-32C `0x82F63B78`, `0xE1351B80`, `0x04C11DB7`), both inits, both xorouts,
output as-is and byte-swapped — only coincidental hits at meaningless
`(start,end)` pairs. Sum32 / `~`sum32 / `-`sum32 likewise.

The break came from a **differential**. Flashing `BM5T-14F397-AG` standalone
worked, which proved the integrity is fully self-contained in the app VBF
(killing the external/NVM/RAM-only theories) and, more usefully, provided a
second known-good image. Diffing the CV4T and BM5T app blocks exposed a
build-specific word at the very end, bracketed by `0xB0F0FFFF` sentinels,
differing where everything around it was identical:

```
... 00008A0C 00002283 00000000 00000004 00000001  B0F0FFFF  <WORD>  B0F0FFFF
CV4T:  WORD = 0xDFCDACD9  at file 0xDCB00 (mem 0xFCB00, = block end - 7)
BM5T:  WORD = 0xCD2F468A  at file 0xDAFD8 (mem 0xFAFD8, = block end - 7)
```

The five preceding fields (`8A0C, 2283, 0, 4, 1`) are identical in both builds;
only the sentinel-wrapped WORD differs. Testing `~CRC32C` over
`[0:0x224) + [0x228:end-7)` reproduced **both** stored words exactly — Rule 0 on
two independent images, which is what promotes it from "plausible" to proven.

> **Lesson worth keeping.** When a checksum resists exhaustive contiguous-CRC
> search, stop brute-forcing and get a second build of the same image. The diff
> localises the word in minutes. Two earlier conclusions in this investigation
> were confidently wrong precisely because they were drawn from one image.

---

## 4. The runtime monitor (mechanism)

A continuous background monitor — not a boot-time check — validates the block
while the module runs:

| item | value |
|---|---|
| tick / driver | `0x91194` (calls validator `0x914C0`, then walks one region step) |
| region walk + compare | `0x91310..0x9144C`, Mode A compare at `0x91410`/`0x91424` |
| zlib CRC-32 engine | entry `0xB5D04`, table mem `0xF058C` |
| CRC-32C engine | entry `0xB5D14`, table mem `0xF018C`, poly `0x82F63B78` |
| accumulator / cursor | RAM `0x821AC8` / `0x821AC4` |
| fault path | `0xB7FE0` (fault codes 24/37/38), report `0x3D4A4` |

Mode A reads the expected word at `*(desc.end - 7)` and compares it to
`~accumulator`. Because the monitor is continuous, a wrong value faults a couple
of seconds after boot — and would equally fault while driving — which is exactly
the observed symptom. The layer-0 recipe above is what that path recomputes.

The descriptor the cursor walks is the **BootNfo triple** inside each flashable
block's header, at descriptor `+0x1C/+0x20/+0x24`:

```
+0x1C  start   (block load address)
+0x20  end     (last byte address, inclusive)
+0x24  stored CRC-32
```

For the CV4T application that triple lives at file `0x21C`:
`00020000 000FCB07 B8B8EC7A`. An earlier reading of this as a bespoke "12-byte
record with relocatable start" was a misinterpretation of this same triple.

### Independent confirmation from the flash logs

The `flash_oem.log` / `flash_mod_bad.log` comparison establishes that the crash
is purely a function of the flashed app-block bytes:

* an OEM reflash with the same flasher always works;
* the 221 `36` transferData chunks reassemble byte-for-byte to the app block —
  there is no separate signature or trailer block;
* the bad download differed from OEM by exactly the code edits plus the
  recomputed BootNfo word, and nothing else;
* `31 01 0304` (finalise) returns the identical `71 01 03 04 10 02` in both
  flashes, so it does not reject anything at flash time, and there is no
  WriteDataByIdentifier and no NVM step.

Therefore the rejecter is a runtime check that is 100 % a function of the
changed app-block bytes — not the flash procedure and not an external value.

---

## 5. Recovery posture

A bad app flash leaves a ~2 s window after power-on in which the module still
answers diagnostics. An OEM reflash of `CV4T-14F397-AF.VBF` inside that window
recovers it; this was exercised repeatedly and is why EXE experimentation was
survivable at all.

Nothing in any OEM VBF erases below `0x3000`, so the primary bootloader and
reset vectors are never at risk.

Do **not** flash a modified EXE hoping to have guessed a layer. Every such
attempt is a ~2 s-recovery cycle that yields no information unless it is a
designed A/B probe.

---

## 6. A/B probe caveat, retained

The slice-0 probe (flipping `0x201A0`) crashing was **not** clean evidence of
whole-block coverage: `0x201A0` is the top byte of an all-`0xFF` word in the
interrupt-vector-table tail, and flipping it to `0x00` turns `0xFFFFFFFF` into
`0x00FFFFFF` — a plausible bad vector address that could fault functionally,
independent of any checksum. Only a probe deep in a data-pool `0xFF` run with no
code or vector references (e.g. `0x0E1A50`) is a clean integrity probe.

Recorded so the same flawed inference is not repeated when designing the next
A/B test.

---

## 7. What was removed

The hands-off escalation modification that originally motivated this work is
**abandoned and deleted**: the clamp produced a permanently "both lines green"
display while doing nothing useful. Removed with it:

```
HANDSOFF_disable.md              CV4T-14F397-AF_HANDSOFF.VBF
work/patch_handsoff.py           work/patch_control.py
work/patch_checksum_test.py      work/verify_exe_monitor.py
CV4T-14F397-AF_CRCTEST.VBF       CV4T-14F397-AF_CRCTEST_S0.VBF
```

Those A/B probes and builders existed only to isolate that build's failure. The
integrity recipe they *uncovered* is what survives, now carried by the neutral
`work/patch_exe_integrity.py`.

**No modified EXE is currently in use on the vehicle.** The validated
modifications are all in the calibration part (`14F398`), which the EXE monitor
does not gate — see `IPMA_speed_gates.md` and `IPMA_LKA_hold_time.md`.
