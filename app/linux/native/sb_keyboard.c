// Backend selection.
//
// evdev is preferred because it is the one implementation that also works on
// Wayland, but it needs the `input` group. XRecord needs no setup at all and
// works on any X11 session, so it is the fallback that lets the app run with
// zero configuration today.

#include "sb_keyboard.h"

static int32_t g_active = SB_BACKEND_NONE;

int32_t sb_start(sb_key_callback cb, int32_t preferred) {
  if (g_active != SB_BACKEND_NONE) return SB_ERR_ALREADY;

  if (preferred == SB_BACKEND_X11) {
    int32_t rc = sb_x11_start(cb);
    if (rc == SB_OK) g_active = SB_BACKEND_X11;
    return rc;
  }

  if (preferred == SB_BACKEND_EVDEV) {
    int32_t rc = sb_evdev_start(cb);
    if (rc == SB_OK) g_active = SB_BACKEND_EVDEV;
    return rc;
  }

  // Auto: evdev, then XRecord.
  int32_t rc = sb_evdev_start(cb);
  if (rc == SB_OK) {
    g_active = SB_BACKEND_EVDEV;
    return SB_OK;
  }

  int32_t rc2 = sb_x11_start(cb);
  if (rc2 == SB_OK) {
    g_active = SB_BACKEND_X11;
    return SB_OK;
  }

  // Report the evdev failure: it is the actionable one (join the input group).
  return rc;
}

void sb_stop(void) {
  switch (g_active) {
    case SB_BACKEND_X11:   sb_x11_stop();   break;
    case SB_BACKEND_EVDEV: sb_evdev_stop(); break;
    default: break;
  }
  g_active = SB_BACKEND_NONE;
}

int32_t sb_active_backend(void) { return g_active; }
