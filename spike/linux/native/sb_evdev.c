// Linux global keyboard backend, reading raw input from /dev/input/event*.
//
// This sits below the display server, so one implementation covers X11 and
// Wayland alike (PLAN.md D2). It needs the user to be in the `input` group;
// without that every open() returns EACCES and start returns
// SB_ERR_NO_PERMISSION, which the caller turns into the setup wizard.
//
// Deliberately uses raw <linux/input.h> rather than libevdev so the build has
// no dependency beyond the kernel headers every distro already ships.

#include "sb_keyboard.h"
#include "sb_internal.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_DEVICES 32

static int              g_fds[MAX_DEVICES];
static int              g_nfds;
static int              g_wake[2] = {-1, -1};  // self-pipe, to break poll()
static pthread_t        g_thread;
static sb_key_callback  g_cb;
static volatile int     g_running;
static int32_t          g_mods;

#define BITS_PER_LONG (sizeof(long) * 8)
#define NBITS(x)      (((x) - 1) / BITS_PER_LONG + 1)
#define TEST_BIT(bit, array) \
  ((array[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1)

// A keyboard, for our purposes, is anything that can emit the whole A-Z block.
// That deliberately excludes power buttons and lid switches, which also
// register as EV_KEY devices.
static int looks_like_keyboard(int fd) {
  unsigned long ev_bits[NBITS(EV_MAX)];
  memset(ev_bits, 0, sizeof ev_bits);
  if (ioctl(fd, EVIOCGBIT(0, EV_MAX), ev_bits) < 0) return 0;
  if (!TEST_BIT(EV_KEY, ev_bits)) return 0;

  unsigned long key_bits[NBITS(KEY_MAX)];
  memset(key_bits, 0, sizeof key_bits);
  if (ioctl(fd, EVIOCGBIT(EV_KEY, KEY_MAX), key_bits) < 0) return 0;

  for (int code = KEY_Q; code <= KEY_P; code++) {
    if (!TEST_BIT(code, key_bits)) return 0;
  }
  return TEST_BIT(KEY_A, key_bits) && TEST_BIT(KEY_Z, key_bits);
}

static void* read_thread(void* arg) {
  (void)arg;
  struct pollfd pfds[MAX_DEVICES + 1];

  while (g_running) {
    for (int i = 0; i < g_nfds; i++) {
      pfds[i].fd = g_fds[i];
      pfds[i].events = POLLIN;
      pfds[i].revents = 0;
    }
    pfds[g_nfds].fd = g_wake[0];
    pfds[g_nfds].events = POLLIN;
    pfds[g_nfds].revents = 0;

    if (poll(pfds, g_nfds + 1, -1) <= 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (pfds[g_nfds].revents & POLLIN) break;  // stop requested

    for (int i = 0; i < g_nfds; i++) {
      if (!(pfds[i].revents & POLLIN)) continue;

      struct input_event ev[32];
      ssize_t n = read(g_fds[i], ev, sizeof ev);
      if (n < (ssize_t)sizeof(struct input_event)) continue;

      const int count = (int)(n / sizeof(struct input_event));
      for (int k = 0; k < count; k++) {
        if (ev[k].type != EV_KEY) continue;

        const int32_t hid = sb_evdev_to_hid(ev[k].code);
        if (hid == 0) continue;

        const int32_t kind = ev[k].value;  // 0/1/2 matches SB_UP/DOWN/REPEAT
        if (kind < SB_UP || kind > SB_REPEAT) continue;

        const int32_t bit = sb_mod_bit_for_hid(hid);
        if (bit) {
          if (kind == SB_DOWN)    g_mods |= bit;
          else if (kind == SB_UP) g_mods &= ~bit;
        }

        // Kernel timestamp, switched to CLOCK_MONOTONIC at open so it shares a
        // base with sb_now_us(). This is the true hardware arrival time.
        const int64_t ts =
            (int64_t)ev[k].time.tv_sec * 1000000 + ev[k].time.tv_usec;

        if (g_cb) g_cb(hid, kind, g_mods, ts);
      }
    }
  }
  return NULL;
}

int32_t sb_evdev_start(sb_key_callback cb) {
  if (g_running) return SB_ERR_ALREADY;

  DIR* dir = opendir("/dev/input");
  if (!dir) return SB_ERR_NO_DEVICE;

  int saw_eacces = 0;
  g_nfds = 0;

  struct dirent* e;
  while ((e = readdir(dir)) != NULL && g_nfds < MAX_DEVICES) {
    if (strncmp(e->d_name, "event", 5) != 0) continue;

    char path[300];
    snprintf(path, sizeof path, "/dev/input/%s", e->d_name);

    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
      if (errno == EACCES) saw_eacces = 1;
      continue;
    }
    if (!looks_like_keyboard(fd)) {
      close(fd);
      continue;
    }
    // Ask the kernel for monotonic timestamps so latency maths is meaningful.
    int clk = CLOCK_MONOTONIC;
    ioctl(fd, EVIOCSCLOCKID, &clk);

    g_fds[g_nfds++] = fd;
  }
  closedir(dir);

  if (g_nfds == 0) {
    return saw_eacces ? SB_ERR_NO_PERMISSION : SB_ERR_NO_DEVICE;
  }

  if (pipe(g_wake) != 0) {
    for (int i = 0; i < g_nfds; i++) close(g_fds[i]);
    g_nfds = 0;
    return SB_ERR_THREAD;
  }

  g_cb   = cb;
  g_mods = 0;
  g_running = 1;

  if (pthread_create(&g_thread, NULL, read_thread, NULL) != 0) {
    g_running = 0;
    close(g_wake[0]); close(g_wake[1]);
    g_wake[0] = g_wake[1] = -1;
    for (int i = 0; i < g_nfds; i++) close(g_fds[i]);
    g_nfds = 0;
    return SB_ERR_THREAD;
  }

  return SB_OK;
}

void sb_evdev_stop(void) {
  if (!g_running) return;
  g_running = 0;

  if (g_wake[1] >= 0) {
    ssize_t ignored = write(g_wake[1], "x", 1);
    (void)ignored;
  }
  pthread_join(g_thread, NULL);

  for (int i = 0; i < g_nfds; i++) close(g_fds[i]);
  g_nfds = 0;
  if (g_wake[0] >= 0) close(g_wake[0]);
  if (g_wake[1] >= 0) close(g_wake[1]);
  g_wake[0] = g_wake[1] = -1;
  g_cb = NULL;
}
