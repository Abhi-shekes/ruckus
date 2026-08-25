// Layout-aware key labels.
//
// The HID tables identify the physical key; what is printed on that key
// depends on the user's layout. On AZERTY the key at HID 0x14 is A, not Q.
// This asks the X server what the active layout actually produces so the UI
// shows the glyph on the user's own keyboard.
//
// Uses Xlib's XKB for the keysym and plain libxkbcommon only to turn that
// keysym into UTF-8. The xkbcommon-x11 helper would be tidier but is a
// separate package that is not always installed; this needs nothing beyond
// what the keyboard backend already links.
//
// Every failure falls back silently to the caller's static US table — a
// plausible label beats no label.

#include "sb_layout.h"
#include "sb_internal.h"

#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

static void g_strlcpy_fallback(char* dst, const char* src, size_t n) {
  if (n == 0) return;
  strncpy(dst, src, n - 1);
  dst[n - 1] = '\0';
}

static Display* g_dpy;
static char     g_layout_name[128];

int32_t sb_layout_init(void) {
  if (g_dpy) return SB_LAYOUT_OK;

  g_dpy = XOpenDisplay(NULL);
  if (!g_dpy) return SB_LAYOUT_ERR_NO_DISPLAY;

  int major = XkbMajorVersion, minor = XkbMinorVersion;
  if (!XkbQueryExtension(g_dpy, NULL, NULL, NULL, &major, &minor)) {
    XCloseDisplay(g_dpy);
    g_dpy = NULL;
    return SB_LAYOUT_ERR_NO_KEYMAP;
  }

  // Best-effort layout name, for display only.
  XkbDescPtr desc = XkbAllocKeyboard();
  if (desc) {
    if (XkbGetNames(g_dpy, XkbGroupNamesMask, desc) == Success &&
        desc->names && desc->names->groups[0] != None) {
      char* name = XGetAtomName(g_dpy, desc->names->groups[0]);
      if (name) {
        g_strlcpy_fallback(g_layout_name, name, sizeof g_layout_name);
        XFree(name);
      }
    }
    XkbFreeKeyboard(desc, 0, True);
  }
  return SB_LAYOUT_OK;
}

int32_t sb_layout_label(int32_t hid_usage, char* out, int32_t out_size) {
  if (!g_dpy || out_size < 2) return SB_LAYOUT_ERR_NO_KEYMAP;

  const int32_t evdev = sb_hid_to_evdev((uint16_t)(hid_usage & 0xFFFF));
  if (evdev <= 0) return SB_LAYOUT_ERR_UNMAPPED;

  // X11 keycodes are evdev codes offset by 8. Group 0, level 0 — the label
  // should read like the key's own legend, not its shifted form.
  const KeySym sym = XkbKeycodeToKeysym(g_dpy, (KeyCode)(evdev + 8), 0, 0);
  if (sym == NoSymbol) return SB_LAYOUT_ERR_UNMAPPED;

  const int n = xkb_keysym_to_utf8((xkb_keysym_t)sym, out, (size_t)out_size);
  // Non-printing keys yield nothing useful; let the caller's table name them.
  if (n <= 1 || out[0] == '\0' || (unsigned char)out[0] < 0x20) {
    return SB_LAYOUT_ERR_UNMAPPED;
  }
  return SB_LAYOUT_OK;
}

const char* sb_layout_name(void) { return g_layout_name; }

void sb_layout_dispose(void) {
  if (g_dpy) XCloseDisplay(g_dpy);
  g_dpy = NULL;
  g_layout_name[0] = '\0';
}
