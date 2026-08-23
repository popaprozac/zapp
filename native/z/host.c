#include "zapp_core.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

  if (result != 0) return result;

  zapp_invoke_service_owned(
    "notes.create",
    "{\"title\":\"Host note\"}",
    2,
    7
  );
  if (
    strcmp(observed_payload, "{\"id\":\"1\",\"title\":\"Host note\"}") != 0
    || observed_request_id != 2
    || !observed_ok
    || observed_window_id != 7
  ) {
    fputs("the direct service entry did not create a typed note\n", stderr);
    return 7;
  }

  zapp_invoke_service_owned("notes.count", "{}", 3, 7);
  if (
    strcmp(observed_payload, "{\"count\":\"1\"}") != 0
    || observed_request_id != 3
    || !observed_ok
  ) {
    fputs("the direct service entry did not retain NotesService state\n", stderr);
    return 8;
  }

  puts("direct service notes.create + notes.count ok");
  return 0;
}

static int32_t benchmark_services(uint64_t iterations) {
  struct timespec started;
  struct timespec finished;
  if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) return 9;
  for (uint64_t index = 0; index < iterations; index += 1) {
    zapp_invoke_service_owned("notes.count", "{}", index, 7);
    if (!observed_ok) return 10;
  }
  if (clock_gettime(CLOCK_MONOTONIC, &finished) != 0) return 11;
  const uint64_t elapsed =
    (uint64_t)(finished.tv_sec - started.tv_sec) * UINT64_C(1000000000)
    + (uint64_t)(finished.tv_nsec - started.tv_nsec);
  const double per_call = iterations == 0
    ? 0.0
    : (double)elapsed / (double)iterations;
  printf(
    "direct service dispatch iterations=%llu total_ns=%llu ns_per_call=%.2f\n",
    (unsigned long long)iterations,
    (unsigned long long)elapsed,
    per_call
  );
  return 0;
}

int main(int argc, char **argv) {
  const bool benchmark = argc > 1 && strcmp(argv[1], "--benchmark") == 0;
  const uint64_t benchmark_iterations = benchmark && argc > 2
    ? strtoull(argv[2], NULL, 10)
    : UINT64_C(100000);
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

  int result = benchmark
    ? benchmark_services(benchmark_iterations)
    : zapp_run_native_host();

  if (zapp_core_runtime_shutdown() != ZAPP_CORE_RUNTIME_OK) {
    fputs("could not shut down the embedded Z runtime\n", stderr);
    if (result == 0) result = 6;
  }
  return result;
}
