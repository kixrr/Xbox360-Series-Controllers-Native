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

### What we do *not* know
The kernel-internal *why* (an off-by-one/cluster-bookkeeping effect in the FATX read
path of 17559) stays unknown. It appears conditional on medium/dirent state: reports
come from FATX-HDD setups; a FAT32/USB copy was not testable here.

### Fix & verification (two stages)
1. **Measured intermediate – `fw_restore`:** wait 800 ms past the read (death window
   +150…300 ms), rewrite main + `.bak` from the RAM copy (`FILE_OVERWRITE_IF` +
   `NtWriteFile`), `.bak` read fallback. Verified over multiple boots: read → GONE →
   `fw: restore … status=0 bytes=70620` → PRESENT, boots without copying,
   power-cut self-heal. (Prototype kept in the session history; later dropped again.)
2. **Final design – the embedded variant:** don't read the file at all. A patcher
   (`tools/embed_firmware.py`) finds a `FWEMBLOB` marker in the built xex, writes
   offset+length and appends the blob; the plugin prefers the blob (one positioned
   `NtReadFile` on its **own** xex) → **zero file I/O on the FATX volume**, so the
   destruction cannot be triggered. Unpatched builds keep the original file behaviour.
   `get-firmware` asks once: *Original* (Jacckii's workflow, just the `.bin`) or
   *Embed* (patch the xex, remove the loose file after a verified patch). A 0-byte
   file now counts as missing instead of dead-ending the boot.

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

- `Add embedded-firmware variant…` — `FWEMBLOB` marker + blob loader (zero file
  I/O) + `get-firmware` Original/Embed choice + 0-byte-file fix. *(Supersedes the
  intermediate `fw_restore`/`.bak` prototype from the same investigation.)*
- `Fix missing on-screen notifications…` — driver-thread inline notify + TLS bind.
