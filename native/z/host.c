#include "zapp_core.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static char observed_message[4096];
static int32_t observed_window_id = -1;

void zapp_route_message_from_z(const char *message, int32_t window_id) {
  if (message == NULL) {
    observed_message[0] = '\0';
  } else {
    (void)snprintf(observed_message, sizeof(observed_message), "%s", message);
  }
  observed_window_id = window_id;
}

int main(int argc, char **argv) {
  const char *message = argc > 1 ? argv[1] : "{\"message\":\"Z core ready\"}";
  const int32_t window_id = 42;

  if (zapp_core_runtime_initialize(NULL) != ZAPP_CORE_RUNTIME_OK) {
    fputs("could not initialize the embedded Z runtime\n", stderr);
    return 2;
  }

  zapp_route_message_owned(message, window_id);
  int result = 0;
  if (strcmp(observed_message, message) != 0) {
    fputs("the Z core changed the routed message\n", stderr);
    result = 3;
  } else if (observed_window_id != window_id) {
    fputs("the Z core changed the routed window identity\n", stderr);
    result = 4;
  } else {
    printf("routed window=%d message=%s\n", observed_window_id, observed_message);
  }

  if (zapp_core_runtime_shutdown() != ZAPP_CORE_RUNTIME_OK) {
    fputs("could not shut down the embedded Z runtime\n", stderr);
    if (result == 0) result = 5;
  }
  return result;
}
