# IPMA Application (EXE) runtime integrity monitor — decode

Why the HANDSOFF EXE patch bricked the module even though the container verified
and the BootNfo CRC-32 was repaired. This is the THIRD integrity layer, missed in
the first attempt. Read-only decode; no patch is safe until §"OPEN" is closed.

## The monitor (proven from code)

Background, chunked, resumable integrity monitor in the Application block
(`CV4T-14F397-AF`, load `0x20000`):

* **Tick/driver:** `0x91194` (calls validator `0x914c0`, then walks one region step).
* **Region walk + compare:** `0x91310..0x9144c`.
* **CRC engines:**
  * CRC-32 entry `0xb5d04` / core `0xb5d24`, table at **mem `0xf058c`**
    (256×u32 BE). Table verified standard zlib polynomial: `T[1]=0x77073096`,
    `T[128]=0xedb88320` → reflected CRC-32/ISO-HDLC.
  * CRC-16 entry `0xb5dd8`, table at **mem `0xf098c`** (poly 0x1021 reflected).
  * Region-with-skip helper `0xb5e00`: CRCs `[start..end)` while **skipping the
    4-byte stored-CRC slot** (`add3 r0,r7,#4`) — BootNfo style.
* **Accumulator** in RAM `0x821ac8`; **region cursor** `0x821ac4` (advances +12
  per region, `0x911c4`); **region count** `0x821b15`; **chunk remaining**
  `0x821acc`.

### Compare semantics (exact)

At region completion (`0x91410`):
```
expected = *(region_desc+4 ...) ; r1 = *0x821ac8 (accumulator) ; not r1,r1
pass if expected == ~accumulator
```
The CRC engine seeds `0xFFFFFFFF` and does **no final XOR**, so `~accumulator`
equals the conventional `zlib.crc32(region)`. Net: **pass iff stored ==
zlib.crc32(region)**. Mismatch sets `r9|=2` → fault path `0xb7fe0` (fault-code
imm #24/#37/#38) and report `0x3d4a4`. It is a **continuous monitor**, not a
boot-only check — consistent with the observed "runs a moment, then diag CAN dies".

## Descriptor structure

12-byte records, walked from RAM pointer `0x821ac4`:
```
+0x00  start   (relocated at generation time: base from sp[20] is ADDED)
+0x04  end
+0x08  flags / stored-CRC reference
```
The generator (`0x25ee0` region, calling `0xb5e00`) **adds a runtime base** to the
start pointer — so the flash descriptors store **relocatable** bounds, not the
absolute addresses seen at runtime. This is why every absolute-address scan below
found nothing.

## OPEN — the one unknown blocking a safe patch

The **region composition** is not yet pinned. Ruled out by exhaustive scan on the
OEM image (all found 0 matches — so none of these is the scheme):

* absolute `[start,end)` with CRC in desc word[2];
* absolute `[start,end]` inclusive, ±1/±3/±4/±8 end conventions;
* CRC stored at `(end-7)` (the runtime idiom) over `[S..E)`/`[S..E-7)`/skip-4;
* file-relative `[a,b)` offsets;
* data-immediately-followed-by-its-CRC running scan from 8 candidate starts.

Zero self-consistent regions on the known-good OEM image ⇒ the composition is
**non-contiguous** (regions concatenated with gaps skipped, and/or spanning the
DSP/calibration parts), exactly the documented Ford pattern where a code CRC is
built to be insensitive to the separately-flashed calibration.

### The deterministic next step (not a guess)

The region table is in RAM `.data`, so `0x821ac4`'s **initial value = &flash_table**
is written by the C-runtime `.data` initializer copied from flash at boot. Two
ways to close it, in order of cost:

1. **Trace `.data` init:** find the startup copy loop that populates
   `0x8218xx..0x821bxx` from its flash source image; the source bytes ARE the
   descriptor table (bounds + stored CRCs + the base/relocation constant). Read
   the composition straight out of it. This is the "read bounds from the firmware"
   discipline and gives the answer without sweeping.
2. **Multi-version differential:** CV4T / F1FT / BM5T are 3 OEM builds. The stored
   region CRCs differ per build; requiring the SAME (algorithm, composition) to
   reproduce all three pins the scheme with ~2^-64 confidence and reveals any
   skipped gap as the region that must be excluded to make all three close.

## Patch discipline (unchanged)

An EXE code edit requires repairing THREE layers in order:
1. this monitor's region CRC-32 (**OPEN** — must be closed first);
2. BootNfo CRC-32 at block `+0x224` (solved: skip-4 zlib, `0xB8B8EC7A`);
3. container block CRC-16 + file CRC-32 (vbftool).

**Do not flash an EXE edit until layer 1 is closed and a `--selftest` reproduces
the monitor's own stored CRCs on the UNMODIFIED OEM image** (skill Rule 0: validate
the hunter on a known-good word before trusting a negative or a fix).

## Verified facts inventory

| item | value | status |
|---|---|---|
| monitor tick | `0x91194` | proven |
| CRC-32 table | mem `0xf058c`, zlib poly | proven |
| CRC-16 table | mem `0xf098c`, 0x1021 refl | proven |
| region-skip helper | `0xb5e00` (skip 4-byte CRC slot) | proven |
| compare | `stored == zlib.crc32(region)` | proven |
| fault path | `0xb7fe0`, report `0x3d4a4` | proven |
| descriptor size | 12 bytes, base-relocated start | proven |
| region composition | non-contiguous, source in RAM `.data` | OPEN |
