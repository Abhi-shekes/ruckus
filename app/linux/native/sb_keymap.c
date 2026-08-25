// evdev keycode -> USB HID usage, and HID usage -> label.
//
// X11 keycodes are evdev codes + 8, so both backends share this one table.

#include "sb_keyboard.h"

#include <stddef.h>
#include <stdio.h>
#include <time.h>

#define HID_PAGE 0x00070000

// Indexed by evdev keycode. 0 means "not mapped".
static const uint16_t kEvdevToHid[256] = {
    [1] = 0x29,                                                  // Escape
    [2] = 0x1E,  [3] = 0x1F,  [4] = 0x20,  [5] = 0x21,           // 1 2 3 4
    [6] = 0x22,  [7] = 0x23,  [8] = 0x24,  [9] = 0x25,           // 5 6 7 8
    [10] = 0x26, [11] = 0x27,                                    // 9 0
    [12] = 0x2D, [13] = 0x2E, [14] = 0x2A, [15] = 0x2B,          // - = Bksp Tab
    [16] = 0x14, [17] = 0x1A, [18] = 0x08, [19] = 0x15,          // Q W E R
    [20] = 0x17, [21] = 0x1C, [22] = 0x18, [23] = 0x0C,          // T Y U I
    [24] = 0x12, [25] = 0x13,                                    // O P
    [26] = 0x2F, [27] = 0x30, [28] = 0x28, [29] = 0xE0,          // [ ] Enter LCtrl
    [30] = 0x04, [31] = 0x16, [32] = 0x07, [33] = 0x09,          // A S D F
    [34] = 0x0A, [35] = 0x0B, [36] = 0x0D, [37] = 0x0E,          // G H J K
    [38] = 0x0F,                                                 // L
    [39] = 0x33, [40] = 0x34, [41] = 0x35, [42] = 0xE1,          // ; ' ` LShift
    [43] = 0x31,                                                 // Backslash
    [44] = 0x1D, [45] = 0x1B, [46] = 0x06, [47] = 0x19,          // Z X C V
    [48] = 0x05, [49] = 0x11, [50] = 0x10,                       // B N M
    [51] = 0x36, [52] = 0x37, [53] = 0x38, [54] = 0xE5,          // , . / RShift
    [55] = 0x55, [56] = 0xE2, [57] = 0x2C, [58] = 0x39,          // Kp* LAlt Space Caps
    [59] = 0x3A, [60] = 0x3B, [61] = 0x3C, [62] = 0x3D,          // F1..F4
    [63] = 0x3E, [64] = 0x3F, [65] = 0x40, [66] = 0x41,          // F5..F8
    [67] = 0x42, [68] = 0x43,                                    // F9 F10
    [69] = 0x53, [70] = 0x47,                                    // NumLock ScrollLock
    [71] = 0x5F, [72] = 0x60, [73] = 0x61, [74] = 0x56,          // Kp7 Kp8 Kp9 Kp-
    [75] = 0x5C, [76] = 0x5D, [77] = 0x5E, [78] = 0x57,          // Kp4 Kp5 Kp6 Kp+
    [79] = 0x59, [80] = 0x5A, [81] = 0x5B,                       // Kp1 Kp2 Kp3
    [82] = 0x62, [83] = 0x63,                                    // Kp0 Kp.
    [87] = 0x44, [88] = 0x45,                                    // F11 F12
    [96] = 0x58, [97] = 0xE4, [98] = 0x54, [99] = 0x46,          // KpEnter RCtrl Kp/ PrtSc
    [100] = 0xE6,                                                // RAlt
    [102] = 0x4A, [103] = 0x52, [104] = 0x4B, [105] = 0x50,      // Home Up PgUp Left
    [106] = 0x4F, [107] = 0x4D, [108] = 0x51, [109] = 0x4E,      // Right End Down PgDn
    [110] = 0x49, [111] = 0x4C,                                  // Insert Delete
    [119] = 0x48,                                                // Pause
    [125] = 0xE3, [126] = 0xE7, [127] = 0x65,                    // LMeta RMeta Menu
    [183] = 0x68, [184] = 0x69, [185] = 0x6A, [186] = 0x6B,      // F13..F16
    [187] = 0x6C, [188] = 0x6D, [189] = 0x6E, [190] = 0x6F,      // F17..F20
    [191] = 0x70, [192] = 0x71, [193] = 0x72, [194] = 0x73,      // F21..F24
};

int32_t sb_evdev_to_hid(uint16_t evdev_code) {
  if (evdev_code >= 256) return 0;
  uint16_t usage = kEvdevToHid[evdev_code];
  return usage ? (int32_t)(HID_PAGE | usage) : 0;
}

int32_t sb_mod_bit_for_hid(int32_t hid_usage) {
  switch (hid_usage & 0xFFFF) {
    case 0xE0: case 0xE4: return SB_MOD_CTRL;
    case 0xE1: case 0xE5: return SB_MOD_SHIFT;
    case 0xE2: case 0xE6: return SB_MOD_ALT;
    case 0xE3: case 0xE7: return SB_MOD_META;
    default: return 0;
  }
}

const char* sb_hid_label(int32_t hid_usage) {
  static char scratch[32];
  int u = hid_usage & 0xFFFF;

  if (u >= 0x04 && u <= 0x1D) {  // A..Z
    scratch[0] = (char)('A' + (u - 0x04));
    scratch[1] = '\0';
    return scratch;
  }
  if (u >= 0x1E && u <= 0x26) {  // 1..9
    scratch[0] = (char)('1' + (u - 0x1E));
    scratch[1] = '\0';
    return scratch;
  }
  if (u == 0x27) return "0";
  if (u >= 0x3A && u <= 0x45) {  // F1..F12
    snprintf(scratch, sizeof scratch, "F%d", u - 0x3A + 1);
    return scratch;
  }
  if (u >= 0x68 && u <= 0x73) {  // F13..F24
    snprintf(scratch, sizeof scratch, "F%d", u - 0x68 + 13);
    return scratch;
  }
  if (u >= 0x59 && u <= 0x61) {  // Numpad1..9
    snprintf(scratch, sizeof scratch, "Num%d", u - 0x59 + 1);
    return scratch;
  }

  switch (u) {
    case 0x28: return "Enter";
    case 0x29: return "Esc";
    case 0x2A: return "Backspace";
    case 0x2B: return "Tab";
    case 0x2C: return "Space";
    case 0x2D: return "Minus";
    case 0x2E: return "Equal";
    case 0x2F: return "BracketLeft";
    case 0x30: return "BracketRight";
    case 0x31: return "Backslash";
    case 0x33: return "Semicolon";
    case 0x34: return "Quote";
    case 0x35: return "Backquote";
    case 0x36: return "Comma";
    case 0x37: return "Period";
    case 0x38: return "Slash";
    case 0x39: return "CapsLock";
    case 0x46: return "PrintScreen";
    case 0x47: return "ScrollLock";
    case 0x48: return "Pause";
    case 0x49: return "Insert";
    case 0x4A: return "Home";
    case 0x4B: return "PageUp";
    case 0x4C: return "Delete";
    case 0x4D: return "End";
    case 0x4E: return "PageDown";
    case 0x4F: return "Right";
    case 0x50: return "Left";
    case 0x51: return "Down";
    case 0x52: return "Up";
    case 0x53: return "NumLock";
    case 0x54: return "NumDivide";
    case 0x55: return "NumMultiply";
    case 0x56: return "NumMinus";
    case 0x57: return "NumPlus";
    case 0x58: return "NumEnter";
    case 0x62: return "Num0";
    case 0x63: return "NumPeriod";
    case 0x65: return "Menu";
    case 0xE0: return "LeftCtrl";
    case 0xE1: return "LeftShift";
    case 0xE2: return "LeftAlt";
    case 0xE3: return "LeftMeta";
    case 0xE4: return "RightCtrl";
    case 0xE5: return "RightShift";
    case 0xE6: return "RightAlt";
    case 0xE7: return "RightMeta";
    default: break;
  }

  snprintf(scratch, sizeof scratch, "0x%04X", u);
  return scratch;
}

int64_t sb_now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
