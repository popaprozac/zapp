#include "probe.h"
#include <stdio.h>

int main(void) {
    // C has NO stdlib JSON — record that as a finding. Either hand-scan
    // sample.json or hardcode (the absence is the data point for "drop to C").
    int w = 640, h = 480;
    const char* title = "zapp-spike";
#ifdef __APPLE__
    spike_cocoa_open_window(w, h, title);
#else
    spike_print_windows();
#endif
    return 0;
}
