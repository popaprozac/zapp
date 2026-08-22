#include "zapp_core.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static char observed_payload[4096];
static uint64_t observed_request_id = 0;
static bool observed_ok = false;
static int32_t observed_window_id = -1;
static const char *input_message = NULL;
static const char *expected_payload = NULL;

static void enqueue_release(
  void *context,
  void *value,
  void (*finalize)(void *value)
) {
  (void)context;
  finalize(value);
}

static bool is_main_thread(void *context) {
  (void)context;
  return pthread_main_np() != 0;
}

void zapp_deliver_response_from_z(
  const char *payload,
  uint64_t request_id,
  bool ok,
  int32_t window_id
) {
  if (payload == NULL) {
    observed_payload[0] = '\0';
  } else {
    (void)snprintf(observed_payload, sizeof(observed_payload), "%s", payload);
  }
  observed_request_id = request_id;
  observed_ok = ok;
  observed_window_id = window_id;
}

int32_t zapp_run_native_host(void) {
  const int32_t window_id = 42;
  zapp_route_message_owned(input_message, window_id);
  int result = 0;
  if (strcmp(observed_payload, expected_payload) != 0) {
    fprintf(
      stderr,
      "unexpected Z payload\nexpected: %s\nobserved: %s\n",
      expected_payload,
      observed_payload
    );
    result = 3;
  } else if (observed_request_id != UINT64_MAX || !observed_ok) {
    fputs("the Z core changed the typed response metadata\n", stderr);
    result = 4;
  } else if (observed_window_id != window_id) {
    fputs("the Z core changed the routed window identity\n", stderr);
    result = 5;
  } else {
    printf(
      "routed window=%d request=%llu ok=%s payload=%s\n",
      observed_window_id,
      (unsigned long long)observed_request_id,
      observed_ok ? "true" : "false",
      observed_payload
    );
  }

  return result;
}

int main(int argc, char **argv) {
  input_message = argc > 1
    ? argv[1]
    : "{\"t\":1,\"id\":18446744073709551615,\"m\":\"__zapp:ping\",\"a\":{\"message\":\"hello from Zapp\"}}";
  expected_payload = argc > 2
    ? argv[2]
    : "{\"message\":\"hello from Zapp\"}";

  const zapp_core_runtime_config config = {
    .context = NULL,
    .enqueue_release = enqueue_release,
    .is_main_thread = is_main_thread,
  };
  if (zapp_core_runtime_initialize(&config) != ZAPP_CORE_RUNTIME_OK) {
    fputs("could not initialize the embedded Z runtime\n", stderr);
    return 2;
  }

  int result = zapp_run_native_host();

  if (zapp_core_runtime_shutdown() != ZAPP_CORE_RUNTIME_OK) {
    fputs("could not shut down the embedded Z runtime\n", stderr);
    if (result == 0) result = 6;
  }
  return result;
}
