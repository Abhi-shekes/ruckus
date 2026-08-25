// System tray via the StatusNotifierItem D-Bus spec.
//
// Deliberately avoids libayatana-appindicator so the build needs nothing
// beyond GTK, which Flutter already requires.

#ifndef SB_TRAY_H
#define SB_TRAY_H

#include <stdint.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SB_TRAY_ITEM_PATH "/StatusNotifierItem"
#define SB_TRAY_MENU_PATH "/MenuBar"

#define SB_TRAY_OK            0
#define SB_TRAY_ERR_ALREADY  -1
#define SB_TRAY_ERR_NO_BUS   -2
#define SB_TRAY_ERR_REGISTER -3

// Menu item kinds.
#define SB_MENU_NORMAL    0
#define SB_MENU_CHECK     1
#define SB_MENU_SEPARATOR 2

// Reserved id delivered when the icon itself is clicked.
#define SB_TRAY_ACTIVATE 1000000

// Called with the id of the clicked menu item, or SB_TRAY_ACTIVATE.
typedef void (*sb_tray_callback)(int32_t item_id);

int32_t sb_tray_start(sb_tray_callback cb);
void    sb_tray_stop(void);

// Rebuild the menu: clear, add items, commit.
void sb_tray_clear_menu(void);
void sb_tray_add_item(int32_t id, const char* label, int32_t kind,
                      int32_t checked, int32_t enabled);
void sb_tray_commit_menu(void);

void sb_tray_set_tooltip(const char* text);
void sb_tray_set_icon(const char* icon_name);

#ifdef __cplusplus
}
#endif

#endif  // SB_TRAY_H
