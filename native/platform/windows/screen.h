// Windows display/screen queries. JSON contract mirrors
// darwin/screen.m: display dicts are
//   { id, name, bounds:{x,y,width,height}, workArea:{...},
//     scaleFactor, isPrimary, rotation }
// in top-left global coordinates. All returns are malloc'd strings
// (caller frees) or NULL on failure.

#ifndef ZAPP_WINDOWS_SCREEN_H
#define ZAPP_WINDOWS_SCREEN_H

#include <stdint.h>

// JSON array of all displays.
char* windows_screen_list_json(void);

// { x, y, display: {...} } for the current cursor position.
char* windows_screen_cursor_json(void);

// Display dict for the monitor hosting the given window (numeric id),
// or NULL when the window doesn't exist.
char* windows_screen_for_window_json(int32_t window_id);

#endif
