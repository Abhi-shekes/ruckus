#include "my_application.h"

#include <X11/Xlib.h>

int main(int argc, char** argv) {
  // Must run before GTK opens its own X connection, and before any other Xlib
  // call in the process.
  //
  // The XRecord keyboard backend reads from a second display connection on its
  // own thread. Xlib keeps per-process global state that is not thread-safe
  // unless this is called first; without it the process aborts inside
  // xcb_io.c the moment both threads talk to X. Calling it from inside the
  // backend is too late — GTK has already connected by then.
  XInitThreads();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
