# IPMA Hands-Off warning + LCA/LKA suppression — disable (Option B)

Goal: for bench/road testing, make IPMA behave as if the driver's hands are
always on the wheel — suppressing BOTH the escalating hands-off warning AND the
lane-centering/keeping cut that follows a long hands-off event.

Read-only research turned into ONE flashable Application VBF. Deliverable:
`CV4T-14F397-AF_HANDSOFF.VBF`. Builder: `work/patch_handsoff.py` (has `--selftest`).

---

## 1. Signal path (ground truth from CAN-HS.dbc)

* `0x140` (= 320, `PSCM_h_FrP01`) — **transmitter: PSCM only**, IPMA is a receiver.
  Byte 7: `LaHandsOff_B_Actl` bit5 (0x20, 1=Hands off / 0=Hands on),
  `LaActDeny_B_Actl` bit4 (0x10), `LaActAvail_D_Actl` bits3:2 (0x0C).
  Byte 6 = `LaActStats_No_Cs` checksum, byte 5 = `LaActStats_No_RollCnt`.
  So "hands on" from IPMA's view = it must read/decide `LaHandsOff = 0`.
* `LaHandsOff_D_Dsply` (IPMA→cluster, on `0x1B5`/`IPMA_h_FrP02` byte2 bits7:6):
  VAL 0=Hands on, 1=Visual, 2=Audible, **3=LCA suppressed**. The escalation
  and the LCA cut are the SAME signal at different levels.

The IPMA COM stack is fully table-driven (generic bit-copy engine, message
descriptor table at mem `0x0E08B4`; the `0x140` record `0017 01FF 0140 0800` at
`0x0E0968` = internal handle 0x17, DLC 8). There is no literal `if(byte7&0x20)`.

---

## 2. The hands-off escalation state machine (proven from code)

Self-contained cluster `0x55378..0x55C84` in the Application block
(`CV4T-14F397-AF`, load `0x20000`). Structure:

```
input request level  [0x809a35] (inst1) / [0x809a74] (inst2)
  -> dwell-timer debounce/escalate helper 0x58068:
       struct+0  = accumulated hands-off time (sth @r6, += elapsed)
       thresholds = 7 x u16 @ 0x804720..0x80472c  (the dwell timers)
       struct+3  = FSM state, advanced when timer > threshold
       struct+8  = COMMITTED escalation level (0..3)
  -> committed level read back at 0x809a9c (inst1) / 0x809aa6 (inst2)
  -> switch(level){0..3} remap -> byte fed to the 0x1B5 COM packer
```

Decisive facts that make this safe to patch:

* `0x58068` has **exactly two callers**, both these gateways — not shared library.
* Every state/output/input global of this machine (`0x809a30/34/35/74/75/76`,
  `0x809a94`, `0x809a9c`, `0x809a9e`, `0x809aa6`) is referenced **only inside**
  the `0x55xxx` cluster. Nothing external reads them.
* Level 3 ("LCA suppressed") is emitted from this one `switch` and NOWHERE else,
  so this single output drives both the warning and the LCA/LKA cut.

---

## 3. The patch — clamp the committed escalation level to 0

At each of the two remap sites, the instruction that loads the committed level
(`ldub r3,@rN`) is replaced with `ldi r3,#0` (dest r3 confirmed by the following
`beqz r3`). Every downstream consumer then sees level 0 = "Hands on" forever.
Received hands-on truth, torque signals and all other lane signals are untouched.

```
mem 0x556f0  ldub r3,@r0   23 90 f0 00  ->  ldi r3,#0 || nop  63 00 f0 00
mem 0x55800  ldub r3,@r3   23 93 f0 00  ->  ldi r3,#0 || nop  63 00 f0 00
```

Both replacements are the identical 4-byte word, same length, parallel-nop kept.

---

## 4. Integrity — three layers, all reproduce (verified)

Application EXE carries a BootNfo descriptor at block offset **0x200** (NOT 0x0
like the calib/SBL parts). `A.D.C._CRCst`, magic `0xAA5AA555`, span = whole block.

```
1. BootNfo CRC-32 @ block +0x224   zlib.crc32, 4 CRC bytes SKIPPED
      stored 0xB8B8EC7A == calc  (pre-patch)   -> 0xC472909A (post)
2. block CRC-16/CCITT-FALSE        0xF859 -> 0xFB54
3. header file_checksum CRC-32     0x78DCA15B -> 0x7C723763
```

Acceptance (both pass):
```
python3 work/patch_handsoff.py --selftest        # identity re-pack byte-exact
vbftool verify CV4T-14F397-AF_HANDSOFF.VBF        # OK (1 blocks)
vbftool diff   CV4T-14F397-AF.VBF  CV4T-14F397-AF_HANDSOFF.VBF
   3 clusters, 8 bytes:  0x020224 BootNfo, 0x0556F0, 0x055800  (+ header digits)
```

---

## 5. Flashing (user does this himself)

EXE part → gated by DID `F188`; erase region `0x20000 len 0xDCB08` (from header,
do not hand-craft). SecurityAccess secret `0x00009875CA` (solved, in
IPMA_flashing.md). SBL `CV4T-14F399-AF.VBF`.

```bash
python3 work/ipma_flash.py --vbf CV4T-14F397-AF_HANDSOFF.VBF \
        --sbl CV4T-14F399-AF.VBF --dry-run     # inspect plan first
```

Recovery posture unchanged: nothing below `0x3000` is erased; a bad image fails
its BootNfo check and stays in boot mode, re-flashable at `0x706`. Full undo =
flash the OEM `CV4T-14F397-AF.VBF`.

> NOTE: `ipma_flash.py` has been validated offline against both OEM captures but
> has not itself driven a live flash. Both prior real flashes used 3rd-party SW.

---

## 6. Caveats / open points (stated honestly)

* This clamps IPMA's OWN escalation verdict. It does NOT alter what PSCM puts on
  `0x140`; other modules (cluster) still receive PSCM's raw `LaHandsOff_B_Actl`.
  For the IPMA test goal (keep LCA/LKA engaged, kill the camera's warning) that
  is exactly right.
* The dwell-timer thresholds at `0x804720..72c` were left untouched — clamping
  the output is more robust than lengthening a timer (no eventual trip).
* Inst1 vs inst2: both patched. Which instance is the live LKA-vs-LCA channel was
  not separately proven; patching both is the conservative choice and each is
  self-contained.
