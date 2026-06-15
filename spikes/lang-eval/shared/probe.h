#ifndef ZAPP_SPIKE_PROBE_H
#define ZAPP_SPIKE_PROBE_H
// Representative of Zapp's darwin/*.m C-ABI surface: ObjC behind plain C.
void spike_cocoa_open_window(int w, int h, const char* title);
void spike_print_windows(void);
// Phase 2: the macOS path for a `dock:bounce`-style platform-gated action.
void spike_cocoa_beep(void);
#endif
