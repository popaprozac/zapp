// iOS shortcuts shim — no system-wide hotkeys on iPhone. iPad has
// UIKeyCommand for in-app keyboard shortcuts but that's a different
// concept (per-view-controller, not global). Phase 4 may add a UIKey-
// Command-based variant for iPad; for now the API is a clean no-op.

#include <stdbool.h>

bool darwin_shortcut_register(const char* accelerator) {
    (void)accelerator;
    return false;  // honest "couldn't register"
}
bool darwin_shortcut_unregister(const char* accelerator) {
    (void)accelerator;
    return false;
}
bool darwin_shortcut_is_registered(const char* accelerator) {
    (void)accelerator;
    return false;
}
void darwin_shortcut_unregister_all(void) { /* no-op */ }
