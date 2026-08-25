// Public C API for the global keyboard backends.
//
// Every backend normalises its native key code to a USB HID usage id on the
// keyboard page (0x00070000 | usage) before the event crosses into Dart, so
// bindings are portable across backends and operating systems. See PLAN.md D5.

#ifndef SB_KEYBOARD_H
#define SB_KEYBOARD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Modifier bitmask.
#define SB_MOD_CTRL  1
#define SB_MOD_SHIFT 2
#define SB_MOD_ALT   4
#define SB_MOD_META  8

// Event kinds.
#define SB_UP     0
#define SB_DOWN   1
#define SB_REPEAT 2

// Backend ids.
#define SB_BACKEND_NONE   0
#define SB_BACKEND_X11    1
#define SB_BACKEND_EVDEV  2

// Start error codes.
#define SB_OK                 0
#define SB_ERR_ALREADY       -1
#define SB_ERR_NO_DISPLAY    -2
#define SB_ERR_NO_XRECORD    -3
#define SB_ERR_NO_CONTEXT    -4
#define SB_ERR_NO_PERMISSION -5
#define SB_ERR_NO_DEVICE     -6
#define SB_ERR_THREAD        -7

// Invoked from a background thread for every key transition.
//   hid_usage : USB HID usage id, already OR-ed with the 0x00070000 page.
//   kind      : SB_UP | SB_DOWN | SB_REPEAT
//   mods      : SB_MOD_* bitmask, tracked by the backend itself
//   ts_us     : CLOCK_MONOTONIC microseconds, stamped as early as possible
typedef void (*sb_key_callback)(int32_t hid_usage, int32_t kind, int32_t mods,
                                int64_t ts_us);

// Backends. Each returns SB_OK or a negative SB_ERR_*.
int32_t sb_x11_start(sb_key_callback cb);
void    sb_x11_stop(void);

int32_t sb_evdev_start(sb_key_callback cb);
void    sb_evdev_stop(void);

// Tries evdev first (works on X11 and Wayland alike), falls back to XRecord.
// Pass a preferred backend or SB_BACKEND_NONE to auto-select.
int32_t sb_start(sb_key_callback cb, int32_t preferred);
void    sb_stop(void);
int32_t sb_active_backend(void);

// Human-readable label for a HID usage, e.g. "A", "F5", "Space". Returns a
// pointer to static storage; never free it.
const char* sb_hid_label(int32_t hid_usage);

// Monotonic clock in microseconds, same base as the ts_us above, so Dart can
// measure the bridge hop against it.
int64_t sb_now_us(void);

#ifdef __cplusplus
}
#endif

#endif  // SB_KEYBOARD_H
