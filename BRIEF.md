# IPMA speed-threshold research — shared briefing

Goal: find where the IPMA camera stores the **LKA / LCA minimum road-speed
thresholds**, so they can be lowered for bench/road testing without a highway.

Observed on the vehicle: **LKA engages ~65 km/h, LCA active from ~80 km/h.**

## Crucial hypothesis — the units are probably mph

```
40 mph = 64.37 km/h   ~ the observed 65
50 mph = 80.47 km/h   ~ the observed 80
```

A US-market Ford camera very likely stores these as **40 / 50 mph**, or as
400 / 500 in 0.1 mph. Search BOTH unit systems; do not assume km/h.

## The firmware set (all containers verified OK, 0 trailing bytes)

| File | Type | Loads at | Size | Description |
|---|---|---|---|---|
| `CV4T-14F397-AF.VBF` | EXE | `0x00020000` | 883 KB | IPMA Release 4.27.0 **Application** |
| `CV4T-14F397-BF.VBF` | EXE | `0x00200000` (+2 tiny blocks at `0x00900048`, `0x00901EB0`) | 1.45 MB | IPMA Release 4.27.0 **DSP Application** |
| `CV4T-14F398-AF.VBF` | DATA | `0x00003000` | 17 KB | IPMA Release 4.27.0 **Application Parameters** |
| `CV4T-14F399-AF.VBF` | SBL | `0x00820000` | 4.9 KB | Secondary Bootloader |

Extracted flat images are in `bins/`, named `<part>_blk<N>_0x<loadaddr>.bin`.
**File offset + load address = memory address.**

`ecu_address = 0x706` (matches `TST_PhysicalReqIPMA`, confirmed on-vehicle).

## Lead already found (verify, don't assume)

`work/scan_speed_consts.py` found `400`/`500` as u16be pairs in the DATA block
at **stride exactly 0x408**, four identical copies:

```
offsets 0x1B7A, 0x1F82, 0x238A, 0x2792   (load 0x04B7A, 0x04F82, 0x0538A, 0x05792)
```

Each sits inside what looks like an ascending breakpoint axis:

```
0  0  50  100  150  200  300  301  400  500  500 | 40  30  20 | 0 0 1000 ...
```

`0 … 500` reads naturally as a curve X-axis in **0.1 mph (0 … 50.0 mph)**, with
`40 30 20` possibly Y-values. Four identical copies suggests per-variant or
per-mode calibration records.

**This is a LOCATOR, not proof.** In a 900 KB image any 16-bit value occurs by
chance ~14 times. Treat every hit as a hypothesis until corroborated by
structure (stride, axis monotonicity, a use-site in code).

## Rules of engagement

* **Read-only research.** Do NOT modify, patch or write any VBF. Deliverable is
  a findings report, not a modified binary.
* Ground every claim in a byte offset + the command that produced it. Say
  "unproven" rather than guessing — a wrong address here bricks a camera.
* Prefer structure over single-value matches: strides, monotonic axes, records
  of constant size, and cross-references from code.
* `vbftool.py` lives at
  `~/.hermes/skills/software-development/vbf-firmware-container/scripts/vbftool.py`
  (`info` / `verify` / `extract` / `merge` / `diff` / `findsum`).
* No venv needed; stdlib python3 only (`/usr/bin/python3` is 3.14).

## Known unknowns

* CPU architecture of each image is **not yet identified** — no compiler
  strings found in the application block. Determine it before claiming any
  disassembly result.
* We have only ONE version of each part, so `vbftool findsum` (which needs two
  OEM versions to discriminate) cannot solve an internal checksum here.
* Whether the thresholds are even in this ECU: the PSCM (`CV6T-14C217`) is the
  module that actually applies steering torque and publishes
  `LaActAvail_D_Actl`. It may hold its own speed gate. Flag this if the IPMA
  evidence is weak.
