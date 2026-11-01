# Investigation notes: firmware destruction & missing on-screen notifications

How the two bugs in this plugin were found, root-caused and fixed — a methodology
write-up so the reasoning (and the evidence behind the fixes) is reviewable without
replaying the whole session.

## Test environment

| | |
|---|---|
| Console | Xbox 360 **Phat, Falcon mainboard**, **RGH** |
| Kernel | retail **17559** |
| Loading | **DashLaunch V3.21 (601)** (`plugin1 = xbdm.xex`, `plugin2 = xa.xex`) + **Aurora 0.7b** |
| Storage | internal **FATX HDD** (`Hdd1:\Apps\xadapter\`) |
| Tooling | xbdm (port 730) driven from a PC: `getmem`/`setmem`/`threadinfo`/`modules`, FTP, custom PPC32 disassembler scripts |

Both fixes were verified live on this console.

---

## Bug 1 — `xone_dongle_02fe.bin` destroyed after the boot read

### Symptom
After each boot the firmware file next to `xa.xex` was gone; it had to be re-copied
over FTP before the next boot. Community reports match ("restarting the console with
the adapter connected the xone_dongle_02fe.bin gets deleted").

### How we isolated it
1. **Boot log timing** (`fswatch` probes): `xa: firmware 70620 bytes …` at +0.02…0.11 s,
   file **GONE at +0.15…0.30 s** — three reproductions, always right after the read.
2. **File-API hooks**: detours on `NtSetInformationFile` (ordinal 247) and
   `NtDeleteFile` (216) installed *before* the read logged every delete-shaped call:
   `fs_deletes = 0` across all sessions → **no delete API is ever called**; the kernel
   destroys the FATX directory entry as a side effect of the read itself.
3. **Control files**: decoy files on the same partition that are *never read* survive
   indefinitely → the trigger is the read, not the plugin's mere existence.
4. **Skip-read test** (`XA_SKIP_FW`): without the read the file lives forever.

### Root cause (resolved upstream after this session: the ninth kernel-call argument)

What stayed open here — the kernel-internal *why* — was closed by upstream commit
`f82c268` („Keep the firmware files: pass NtCreateFile's ninth argument where the
kernel reads it"): **`NtCreateFile` takes nine arguments; clang (32-bit PPC ABI) puts
the ninth — the create options — on the stack at `96(r1)`, while the 360 kernel
(64-bit-register ABI) reads it from `0x54(r1)`.** The kernel therefore consumed stale
stack data as create options, and with `FILE_DELETE_ON_CLOSE` among those bits the file
deleted itself as soon as the plugin closed the handle. No delete API call was ever
seen (point 2 above) precisely because the deletion rides the close path.

That mechanism retro-explains every measurement this session produced:

- **The flag matrix showed "flags don't matter"** — `attr`/`share`/`disp` are
  arguments 6–8 (registers, they arrived); `opt` was the *ninth* argument and never
  reached the kernel at all. We had varied a variable the kernel never read.
- **Boot-dependent `c0000103` (STATUS_NOT_A_DIRECTORY) on every file of the volume** —
  stale options containing `FILE_DIRECTORY_FILE` make the kernel treat a file open as a
  directory open. Call-site dependent, not file dependent; the FTP server's own opens
  (different binary, different stack) never saw it.
- **The "kill window" (early opens destroy, late opens mostly survive)** — the stack
  slot's content changes as the driver thread runs (`wait_ms` loops overwrite it):
  early it carried the delete/directory bits, later not. Timing correlated, the kernel
  was not on a timer.
- **Failed opens were harmless** — no handle, no close, nothing to delete.

So the *fix* is the ABI correction (`xa_kcall9` in `thunks.s`, rule added to
`docs/INTERNALS.md`); the file-based workflow became safe with it. The measurements
above remain the evidence for *how the symptom looked* before that fix existed.

### Fix & verification (three stages)
1. **Measured intermediate – `fw_restore`:** wait 800 ms past the read (death window
   +150…300 ms), rewrite main + `.bak` from the RAM copy (`FILE_OVERWRITE_IF` +
   `NtWriteFile`), `.bak` read fallback. Verified over multiple boots: read → GONE →
   `fw: restore … status=0 bytes=70620` → PRESENT, boots without copying,
   power-cut self-heal. (Prototype kept in the session history; later dropped again.)
2. **Intermediate design – the appended blob:** don't read the *firmware* file. A
   patcher (`tools/embed_firmware.py`, kept in the session history) appended the blob
   after the xex and the plugin read it back through its own image file. This proved
   the zero-I/O principle but still performed one file open of `xa.xex` itself — and
   the very bug above could eat *that* file, which ended this variant's life.
3. **Final design – the `XAFWSLOT`:** the firmware lives in a fixed-size const slot
   inside the mapped image (`fw_slot.h`; emitted always by `fw_to_c.py`, filled at
   build time or left empty for distribution). The plugin copies it **from mapped
   memory at t=0 — zero file I/O, no open, no create options, nothing on the FATX
   volume involved**. The shipped `dist/xa.xex` carries an empty slot (no firmware
   bytes in the repo); `tools/patch_slot.py` fills it in place after download —
   same safety as a compile-in, no toolchain needed. `get-firmware` asks once:
   **[E]** patches the slot (removes the loose 02fe file afterwards, keeps 02e6) or
   **[O]** keeps the classic file workflow, which upstream's `xa_kcall9` fix made safe.
   A 0-byte file counts as missing instead of dead-ending the boot.

   Verified on the console: `firmware 70620 bytes from ROM slot (mapped image)` at
   t≈0.01 s, `state=9 RUNNING`, ready-toast, `xa.xex` intact over consecutive
   reboots, no firmware file present on the console at all.

---

## Bug 2 — `XNotifyQueueUI` calls never produced a toast

### Symptom
Plugin notifications ("Wireless adapter: ready", custom toasts) never appeared on
this console, while achievement toasts (XAM's own renderer) worked.

### How we isolated it (in order)
1. **Parameter sweep**: 39 fires over an areas/user/type matrix, all acked by the
   plugin (log line written *after* the call) → **0 toasts** → not a parameter problem.
2. **Suppression hunt**: `launch.ini` (17 candidate keys incl. `signnotice`) and all
   readable Aurora configs clean → no config suppresses notifications.
3. **Context tests**: same result in-game and in the dashboard → not title-dependent.
4. **XAM reverse engineering** (live disassembly via xbdm `getmem` + a PPC32
   disassembler): export wrapper → packer → dispatcher. The dispatcher picks a
   *direct* path only when `KeGetCurrentProcessType() == 2`, else an indirect path
   whose insert switch rejects unknown messages by default.
5. **Live gate measurements**: every producer-side gate read green (context magic
   `0xaaaabbbb`, RW-lock `state=-1`, area chain, singleton, alloc flags), yet…
6. **The decisive metrics**: a pending counter (`0x81AA07AC`) that rose with every
   fire while the entry list stayed **empty** → each create attempt died *after* the
   increment and *before* the link — the signature of a failed create, not a failed
   render. The destructor (the only decrementer) was never referenced by any code path.
7. **Boot-window probes**: counter/list/init state sampled across reboots (remote
   `magicboot cold`), showing the create never succeeded at any time of a boot.
8. **Thread forensics** (`xbdm threadinfo`, no attach needed): the driver thread has
   **`proc=0x02`**, the XAM-hook thread **`proc=0x04`**. The dispatcher's
   `KeGetCurrentProcessType()==2` test therefore sent every queued notify down the
   rejecting path — on this console, deterministically.
9. **Second gate found while fixing**: the create path also reads a per-thread notify
   context via `TlsGetValue`; nothing ever binds that slot for our thread (XAM's only
   binder runs in init windows and clears the slot when the window ends).

### Fixes
- Run notify requests **inline on the driver thread** (`proc=0x02` → dispatcher takes
  the direct path that accepts the message).
- **Bind the TLS slot** (`TlsSetValue` ord 341, index from `0x81A82570`) right before
  each call, with the notify singleton as the context object.

### Verification numbers
| Step | Counter | Refcount `*(ctx+4)` | Entry list | Meaning |
|---|---|---|---|---|
| fire 1 | 0 → 1 | 71 → 72 | 0 → **1** | create succeeded (first ever) |
| fire 2 | 1 → **0** | 72 → 62 | 1 → 0 | merge + **consumer ran, destructor freed, balanced** |
| screen | — | — | — | toast **"xa debug notify" visible on TV** ✓ |

---

## Tools used (all read-only except the noted fires)

- `getmem`/`setmem`/`threadinfo`/`modules` over xbdm; FTP for file verification.
- PPC32 disassembly scripts (`disasm_notify_real.py`, `FN`/`COUNT` env), targeted
  scans (callers/pointers/instruction patterns), live struct/counter readers.
- Remote reboot: xbdm **`magicboot cold`** (plain `magicboot` is acked but does not
  restart on this setup).
- Key XAM addresses and the full session log live in the maintainer's session notes.

## Related fixes in this repository

- **Upstream** (merged before this branch): `f82c268` — `xa_kcall9` puts the ninth
  `NtCreateFile` argument where the kernel reads it (the root cause above); `3093673` —
  original adapter `045e:02e6` support; `4559549` — on-screen *firmware missing*
  notices. *(The appended-blob and `fw_restore` variants of this investigation are
  superseded by the slot below.)*
- `Add the XAFWSLOT…` (PR 1) — firmware inside the mapped image, read at t=0 with
  zero file I/O; `tools/patch_slot.py` fills the slot without a toolchain
  (`get-firmware [E]`); 0-byte-file fix.
- `Fix missing on-screen notifications…` (PR 2) — driver-thread inline notify + TLS
  bind; also what makes the upstream *firmware missing* toasts actually appear.
