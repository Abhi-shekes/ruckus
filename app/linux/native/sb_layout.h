// Layout-aware key labels via xkbcommon.

#ifndef SB_LAYOUT_H
#define SB_LAYOUT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SB_LAYOUT_OK              0
#define SB_LAYOUT_ERR_NO_DISPLAY -1
#define SB_LAYOUT_ERR_NO_KEYMAP  -2
#define SB_LAYOUT_ERR_UNMAPPED   -3

int32_t     sb_layout_init(void);
// Writes the UTF-8 glyph this physical key produces on the active layout.
int32_t     sb_layout_label(int32_t hid_usage, char* out, int32_t out_size);
const char* sb_layout_name(void);
void        sb_layout_dispose(void);

#ifdef __cplusplus
}
#endif

#endif  // SB_LAYOUT_H
