# IPMA flashing — procedure, security access, recovery

Everything here is derived from **two captured OEM flash sessions**
(`candump-stock-flash.log`, `candump-mod-flash.log`), not from assumption.

---

## 1. SecurityAccess secret — `0x00009875CA`

Every Ford ECU uses the same LFSR keygen with a **different 40-bit secret**, so
it cannot be guessed:

```
BCM  0x726 : 0x64000B0C59   verified on hardware
PSCM 0x730 : 0x00009B2533   published, unverified
IPMA 0x706 : 0x00009875CA   SOLVED and cross-validated
```

### How it was recovered — linear algebra, not brute force

The keygen is **affine over GF(2)**: the state starts at a constant and each
round XORs in one input bit; seed and secret occupy disjoint fields combined
with OR, and OR over disjoint fields *is* XOR. There are no seed×secret
products, so

```
key(seed, secret) = A·seed  XOR  B·secret  XOR  c
```

and `B` does not depend on the seed. Therefore
`delta = key(seed, secret) XOR key(seed, 0) = B·secret` is the same 24-bit
vector for every seed — **one captured pair determines it** by Gaussian
elimination, in microseconds. 2^40 brute force would take days.

`B` is 24×40, so the kernel has dimension ≥16: ~65 536 secrets produce
identical keys for every seed. Any member works.

### Cross-validation — the part that actually proves it

| session | seed | key |
|---|---|---|
| stock | `3450FC` | `2B3A70` |
| mod | `50E4BE` | `41C1BA` |

```
secret from STOCK session only : 0x00009875ca
secret from MOD   session only : 0x00009875ca      identical

stock-derived -> predicts MOD pair   : seed 50E4BE expected 41C1BA got 41C1BA  MATCH
mod-derived   -> predicts STOCK pair : seed 3450FC expected 2B3A70 got 2B3A70  MATCH
```

Fitting one pair could be luck. **Correctly predicting an unseen seed cannot.**

Tool: `work/ford_seckey_solve.py` — 15 self-tests, including re-deriving the
hardware-verified BCM secret as a positive control, and rejecting a wrong
secret as a negative control.

```bash
python3 work/ford_seckey_solve.py --from-candump candump-....log
```

It only accepts a pair the ECU actually acknowledged with `67 02`; a key that
drew `7F 27 35` (invalidKey) is discarded.

---

## 2. The real flash sequence

Captured verbatim from the OEM tool (`candump-mod-flash.log`, ~16 s):

```
 0.00  -> 22 F1 13                     read hardware part
 0.05  <- 62 F1 13 'BM5T-19H406-AG'
 0.16  -> 22 F1 88                     read application part
 0.21  <- 62 F1 88 'CV4T-14F397-AF'
 5.92  -> 10 02                        programmingSession
 5.93  <- 50 02 00 19 01 F4
 6.98  -> 27 01                        requestSeed
 6.98  <- 67 01 50 E4 BE
 6.98  -> 27 02 41 C1 BA               sendKey
 6.98  <- 67 02                        accepted
 7.18  -> 34 00 44 00820000 00001330   requestDownload  SBL -> RAM
 7.18  <- 74 20 0F FF                  maxBlockLength 0x0FFF
        ...  36 xx <4093 B>  ...
 7.70  -> 37                           transferExit
 7.78  -> 31 01 03 01 00 82            START THE SBL  (high half of 0x820000)
 7.80  <- 71 01 03 01 10
 8.14  -> 31 01 FF 00 00003000 00004428   eraseMemory
 8.94  <- 71 01 FF 00 10
12.03  -> 34 00 44 00003000 00004428   requestDownload  calibration
        ...  36 xx <4093 B>  ...
14.11  -> 37                           transferExit
15.43  -> 31 01 03 04                  FINALISE / checkMemory
15.43  <- 71 01 03 04 10 02
15.69  -> 11 01                        ECUReset
```

### Four corrections to our first flasher implementation

Each was written by analogy with the BCM flasher and was **wrong**; each would
have failed or degraded a real flash:

1. **Identity DID.** We read `F124` for a DATA part. The OEM tool reads
   **`F113` + `F188`**, and `F188` returns the *application* part
   (`CV4T-14F397-AF`) which **never equals a calibration VBF's own part
   number** (`CV4T-14F398-AF`). An equality check there refuses every
   legitimate calibration flash.
2. **SBL start routine.** Not `31 01 FF01 <32-bit address>` but
   **`31 01 0301 0082`** — routine `0301` with the *high half* of the call
   address.
3. **Missing finalise.** The OEM tool runs **`31 01 0304`** after the download
   and before the reset. Omitting it leaves the part written but unvalidated.
4. **Block size.** Not a hardcoded `0x402`. The ECU declares
   **`74 20 0F FF`** = `0x0FFF`, i.e. **4093** payload bytes per `36` (SID and
   sequence take 2). Smaller works but is ~4× slower; larger earns NRC `0x73`.

`work/ipma_flash.py` implements the corrected sequence. Its self-tests replay
both captures and assert the bytes it would transmit match the OEM ones.

---

## 3. Proof a flash landed correctly

Reassembling the `0x36` payloads from each capture and comparing to our files:

```
candump-stock-flash.log : 17448 B -> IDENTICAL to CV4T-14F398-AF.VBF
candump-mod-flash.log   : 17448 B -> IDENTICAL to CV4T-14F398-AF_LKA40_LCA45.VBF
```

Byte-for-byte. This is stronger evidence than a DTC read: it shows exactly
what the module received.

---

## 4. Integrity layers — repair order matters

A modified calibration must repair **three** layers, in this order:

1. **BootNfo CRC-32** at block `+0x24` — `zlib.crc32` over the block with those
   4 bytes *skipped*. **`vbftool` does not do this.**
2. **Per-block CRC-16/CCITT-FALSE** — `vbftool` handles it.
3. **Header `file_checksum` CRC-32** — `vbftool` handles it.

Skipping layer 1 leaves the module failing its own boot-time integrity check.

`work/patch_thresholds.py` does all three and refuses to run if any edit site
does not hold its expected OEM value.

Acceptance test for any modified VBF:

```bash
T=~/.hermes/skills/software-development/vbf-firmware-container/scripts/vbftool.py
python3 $T verify OUT.VBF          # all CRCs
python3 $T diff   OEM.VBF OUT.VBF  # ONLY the expected clusters
```

A correct threshold patch shows the edited floats, the BootNfo word, the block
CRC and the header digits — **nothing else**:

```
8 differing cluster(s), 20 bytes total
  0x003024  BootNfo CRC-32   cedef18d -> 628330f1
  0x005455  LKA m/s pair
  0x005DE5  LKA arm (tag58)  64.6 -> 40.0
  0x006349..0x0064ED  LCA arm x4   80.0 -> 45.0
  0x006AE1  LKA arm (tag48)  64.6 -> 40.0
```

---

## 5. Recovery posture — fails safe

* **Nothing in any OEM VBF erases below `0x3000`.** The primary bootloader and
  reset vectors are never touched by a field-flashable part.
* **The SBL is RAM-loaded** (`call 0x820000`, no erase region), so it cannot be
  persistently corrupted.
* A bad image **fails its BootNfo check and stays in boot mode** — the module
  remains addressable at `0x706` and re-flashable. It fails into a recoverable
  state rather than running corrupt ADAS code.
* The calibration part has its **own isolated erase region** (`0x3000`, len
  `0x4428`) which does not intersect the 883 KB application. Re-flashing the
  OEM 17 KB part is a complete undo.

**Never alter erase-region fields in a VBF header.** A hand-crafted region
could erase the bootloader and genuinely brick the module.

**Do not patch the F1FT generation** — its BootNfo descriptor differs and its
CRC has not been reproduced, so it cannot be repaired after an edit.

---

## 6. Usage

```bash
# dry run — prints the full plan, transmits nothing
python3 work/ipma_flash.py --vbf OUT.VBF --sbl CV4T-14F399-AF.VBF --dry-run

# live (secret defaults to the solved value)
python3 work/ipma_flash.py --vbf OUT.VBF --sbl CV4T-14F399-AF.VBF --execute
```

Battery charger on, ignition on, engine off. ~16 s for a 17 KB part.

> **Note.** `ipma_flash.py` has been validated offline against both captures
> but has **not itself performed a flash on the vehicle** — both real flashes
> were done with third-party software. Treat its first live run accordingly.
