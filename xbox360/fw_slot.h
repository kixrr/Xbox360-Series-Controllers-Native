/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * XAFWSLOT - the firmware slot inside the plugin image.
 *
 * fw_to_c.py (build.sh) emits the object with a fixed capacity, filled at compile
 * time when a firmware file is given, or left empty (len 0) otherwise. An empty
 * slot gets filled afterwards - without a toolchain - by tools/patch_slot.py
 * (get-firmware [E]): the bytes land INSIDE the mapped PE, so the plugin reads
 * them from memory at t=0 with ZERO file I/O (no open, no FATX dirent kill-window,
 * no loader header games). Only when the slot is empty does the plugin fall back
 * to the blob/file sources (gated behind FILE_OPEN_DELAY_MS).
 *
 * Layout is part of the patcher contract: magic 0..7, len 8..11 (big endian, the
 * 360 is PPC), data from 12. Do not reorder.
 */
#ifndef XA_FW_SLOT_H
#define XA_FW_SLOT_H

/* keep in sync with FIRMWARE_MAX in xa_plugin.c (and patch_slot.py) */
#define XA_FW_SLOT_MAX 0x20000

struct xa_fw_slot {
	char magic[8];			  /* "XAFWSLOT" */
	unsigned int len;		  /* firmware bytes, big endian; 0 = empty */
	unsigned char data[XA_FW_SLOT_MAX];
};

extern const struct xa_fw_slot xa_fw_slot;

/* layout is a patcher contract: catch compiler surprises at build time */
typedef char xa_fw_slot_layout_check[
	(sizeof(struct xa_fw_slot) == 12 + XA_FW_SLOT_MAX) ? 1 : -1];

#endif
