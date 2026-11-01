#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""patch_slot.py - schreibt die Firmware in den XAFWSLOT des xa.xex (in-place).

Der Slot lebt INNERHALB des gemappten PE-Bildes (fw_slot.h). Das Plugin liest ihn
per Zeiger ab t=0 - kein Datei-Open, kein FATX-Dirent-Killfenster, kein Loader-
Header-Spiel (image_size bleibt unangetastet). Damit ist die Patch-Sicherheit
identisch mit einem Compile-in (ROM)-Build, braucht aber keine Toolchain.

Das ist der Hauptpfad von get-firmware [E]; der aeltere Blob-Anhaenger
(embed_firmware.py) bleibt nur fuer Alt-Builds ohne Slot als Fallback.

Aufruf:
  python patch_slot.py XEX FW.bin     XEX in-place patchen (len + Daten)
  python patch_slot.py --check XEX    Slot-Inhalt melden (ohne FW-Vergleich)

Exit: 0 ok, 2 kein XAFWSLOT im XEX, 3 Fehler (Laenge/Layout/Datei).
WICHTIG wie bei allen Patchern: die Firmware-Bytes landen NIE im Repo - nur in
der lokalen Kopie des XEX, das der User auf seine Konsole kopiert.
"""
import hashlib
import struct
import sys

MAGIC = b"XAFWSLOT"
CAP = 0x20000  # XA_FW_SLOT_MAX in fw_slot.h / FIRMWARE_MAX in xa_plugin.c
DATA_OFF = 12  # magic(8) + len(4), layout contract from fw_slot.h


def sha(d):
    return hashlib.sha256(d).hexdigest()


def find_slot(d):
    i = d.find(MAGIC)
    if i < 0:
        print("XAFWSLOT nicht gefunden - das XEX wurde ohne Slot gebaut")
        print("(get-firmware nutzt dann den Blob-Fallback; oder mit aktuellem")
        print(" build.sh neu bauen).")
        sys.exit(2)
    if d.find(MAGIC, i + 1) >= 0:
        print("XAFWSLOT mehrfach gefunden - unerwartetes Layout")
        sys.exit(3)
    if i + DATA_OFF + CAP > len(d):
        print(f"Slot ragt hinter das Dateiende ({i:#x}+{DATA_OFF}+{CAP:#x} > "
              f"{len(d):#x}) - ungepuffertes/out-of-date XEX?")
        sys.exit(3)
    return i


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(3)

    if args[0] == "--check":
        if len(args) < 2:
            print(__doc__)
            sys.exit(3)
        d = open(args[1], "rb").read()
        i = find_slot(d)
        ln = struct.unpack_from(">I", d, i + 8)[0]
        data = d[i + DATA_OFF:i + DATA_OFF + min(ln, CAP)]
        print(f"Slot @ {i:#x}: len={ln} ({ln:#x}) "
              f"sha256={sha(data)[:16] if ln else '-'}...")
        if ln > CAP:
            print("len > Kapazitaet - Slot-Inhalt unplausibel")
            sys.exit(3)
        print(f"XEX: {len(d)} B sha256={sha(d)[:16]}...")
        return

    if len(args) < 2:
        print(__doc__)
        sys.exit(3)
    xex_path, fw_path = args[0], args[1]

    fw = open(fw_path, "rb").read()
    if not (1024 <= len(fw) <= CAP):
        print(f"Firmware-Laenge unerwartet: {len(fw)} (1024..{CAP:#x})")
        sys.exit(3)

    d = bytearray(open(xex_path, "rb").read())
    i = find_slot(d)
    # begrenzen: ein korrupter len-Wert darf das Nullen nicht ausserhalb des Slots ziehen
    old = min(struct.unpack_from(">I", d, i + 8)[0], CAP)
    print(f"XEX:     {xex_path}  {len(d)} B  sha256={sha(bytes(d))[:16]}...")
    print(f"Firmware: {fw_path}  {len(fw)} B  sha256={sha(fw)[:16]}...")
    print(f"Slot @ {i:#x}: len {old} -> {len(fw)}")

    struct.pack_into(">I", d, i + 8, len(fw))
    d[i + DATA_OFF:i + DATA_OFF + len(fw)] = fw
    # Rest des Slots nullen (a) gegen Alt-Reste, (b) Damit der XEX keine
    # Firmware-Ausschnitte aus einer frueheren Patchung traegt, wenn mal
    # eine kuerzere Firmware reflashet wird.
    if old > len(fw):
        for off in range(i + DATA_OFF + len(fw), i + DATA_OFF + old):
            d[off] = 0

    open(xex_path, "wb").write(bytes(d))

    # Roundtrip: len + sha der geschriebenen Bytes zuruecklesen
    r = open(xex_path, "rb").read()
    i2 = find_slot(r)
    got_len = struct.unpack_from(">I", r, i2 + 8)[0]
    got = r[i2 + DATA_OFF:i2 + DATA_OFF + got_len]
    ok = (i2 == i and got_len == len(fw) and sha(got) == sha(fw))
    print("--- Verifikation ---")
    print(f"  len={got_len}  sha256={sha(got)[:16]}...  "
          f"{'stimmt mit FW-Datei ueberein' if ok else 'MISMATCH!'}")
    print(f"  XEX: {len(r)} B sha256={sha(r)[:16]}...")
    if not ok:
        sys.exit(3)


if __name__ == "__main__":
    main()
