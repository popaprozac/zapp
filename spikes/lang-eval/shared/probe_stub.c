#include <stdio.h>
#include "probe.h"
void spike_cocoa_open_window(int w, int h, const char* title) {
    (void)w; (void)h; (void)title;
    (void)fprintf(stdout, "[spike] cocoa stub (non-darwin build)\n");
}
void spike_print_windows(void) {
    (void)fprintf(stdout, "[spike] windows path (stub)\n");
}
