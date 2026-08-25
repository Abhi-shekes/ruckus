// X11 global keyboard backend, via the XRecord extension.
//
// XRecord taps the server's event stream for *all* clients, so keys arrive
// whether or not our window has focus. It does not intercept: the focused
// application still receives every key. That matches the Linux capability
// contract in PLAN.md D2 (canSuppress == false).
//
// Requires two display connections. The data connection blocks inside
// XRecordEnableContext for the lifetime of the capture, which is why it lives
// on its own thread; the control connection exists so another thread can
// disable the context to break that loop.

#include "sb_keyboard.h"
#include "sb_internal.h"

#include <X11/Xlib.h>
#include <X11/Xproto.h>
#include <X11/extensions/record.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static Display*         g_ctrl;
static Display*         g_data;
static XRecordContext   g_ctx;
static pthread_t        g_thread;
static sb_key_callback  g_cb;
static volatile int     g_running;
static int32_t          g_mods;
static unsigned char    g_down[256];  // by X keycode, for auto-repeat detection

static void on_record(XPointer closure, XRecordInterceptData* d) {
  (void)closure;
  const int64_t ts = sb_now_us();

  if (d->category != XRecordFromServer || d->data_len < 1) goto done;

  {
    const unsigned char* b = (const unsigned char*)d->data;
    const int type    = b[0] & 0x7F;
    const int keycode = b[1];

    if (type != KeyPress && type != KeyRelease) goto done;

    // X11 keycodes are evdev codes offset by 8.
    const int32_t hid = sb_evdev_to_hid((uint16_t)(keycode - 8));
    if (hid == 0) goto done;

    int32_t kind;
    if (type == KeyPress) {
      kind = g_down[keycode] ? SB_REPEAT : SB_DOWN;
      g_down[keycode] = 1;
    } else {
      kind = SB_UP;
      g_down[keycode] = 0;
    }

    // Track modifiers ourselves rather than trusting the state field, which is
    // not reliably populated in the record stream.
    const int32_t bit = sb_mod_bit_for_hid(hid);
    if (bit) {
      if (kind == SB_DOWN)    g_mods |= bit;
      else if (kind == SB_UP) g_mods &= ~bit;
    }

    if (g_cb) g_cb(hid, kind, g_mods, ts);
  }

done:
  XRecordFreeData(d);
}

static void* record_thread(void* arg) {
  (void)arg;
  // Blocks until the context is disabled from the control connection.
  XRecordEnableContext(g_data, g_ctx, on_record, NULL);
  return NULL;
}

int32_t sb_x11_start(sb_key_callback cb) {
  if (g_running) return SB_ERR_ALREADY;

  XInitThreads();

  g_ctrl = XOpenDisplay(NULL);
  if (!g_ctrl) return SB_ERR_NO_DISPLAY;

  int major = 0, minor = 0;
  if (!XRecordQueryVersion(g_ctrl, &major, &minor)) {
    XCloseDisplay(g_ctrl);
    g_ctrl = NULL;
    return SB_ERR_NO_XRECORD;
  }

  // A second connection is mandatory: the data one is monopolised by the
  // blocking enable call below.
  g_data = XOpenDisplay(NULL);
  if (!g_data) {
    XCloseDisplay(g_ctrl);
    g_ctrl = NULL;
    return SB_ERR_NO_DISPLAY;
  }

  XRecordRange* range = XRecordAllocRange();
  if (!range) {
    XCloseDisplay(g_data);
    XCloseDisplay(g_ctrl);
    g_data = g_ctrl = NULL;
    return SB_ERR_NO_CONTEXT;
  }
  memset(range, 0, sizeof *range);
  range->device_events.first = KeyPress;
  range->device_events.last  = KeyRelease;

  XRecordClientSpec clients = XRecordAllClients;
  g_ctx = XRecordCreateContext(g_ctrl, 0, &clients, 1, &range, 1);
  XFree(range);

  if (!g_ctx) {
    XCloseDisplay(g_data);
    XCloseDisplay(g_ctrl);
    g_data = g_ctrl = NULL;
    return SB_ERR_NO_CONTEXT;
  }
  XSync(g_ctrl, False);

  g_cb   = cb;
  g_mods = 0;
  memset(g_down, 0, sizeof g_down);
  g_running = 1;

  if (pthread_create(&g_thread, NULL, record_thread, NULL) != 0) {
    g_running = 0;
    XRecordFreeContext(g_ctrl, g_ctx);
    XCloseDisplay(g_data);
    XCloseDisplay(g_ctrl);
    g_data = g_ctrl = NULL;
    return SB_ERR_THREAD;
  }

  return SB_OK;
}

void sb_x11_stop(void) {
  if (!g_running) return;
  g_running = 0;

  XRecordDisableContext(g_ctrl, g_ctx);
  XFlush(g_ctrl);
  pthread_join(g_thread, NULL);

  XRecordFreeContext(g_ctrl, g_ctx);
  XCloseDisplay(g_data);
  XCloseDisplay(g_ctrl);
  g_data = g_ctrl = NULL;
  g_ctx  = 0;
  g_cb   = NULL;
}
