#ifndef SB_INTERNAL_H
#define SB_INTERNAL_H

#include <stdint.h>

// Shared by both backends, implemented in sb_keymap.c.
int32_t sb_evdev_to_hid(uint16_t evdev_code);
int32_t sb_mod_bit_for_hid(int32_t hid_usage);

#endif  // SB_INTERNAL_H
