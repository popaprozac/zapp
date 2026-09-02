#include "zapp_worker_zjs.h"

#include <zjs.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

struct ZappZjsEngine {
  ZjsContext *context;
  uint32_t command_handle;
  int has_command_handler;
  char *response_channel;
  char *response_payload;
  char error[512];
};

struct ZappZjsWorker {
  ZappWorkerRuntime runtime;
  pthread_t thread;
  _Atomic int cancellation_requested;
  int started;
  int joined;
  int32_t result;
  void *source;
  char *module_name;
};

static void cancel_worker_runtime(ZappWorkerRuntime *runtime);
static int32_t join_worker_runtime(ZappWorkerRuntime *runtime);
static void destroy_worker_runtime(ZappWorkerRuntime *runtime);

// ZJS host functions do not carry embedder data yet. Each engine remains
// confined to one worker thread, so a thread-local entered engine is enough
// to route synchronous host calls without a process-global lock.
static _Thread_local ZappZjsEngine *entered_engine;

static char *copy_string_bytes(const char *bytes, uint32_t length) {
  if (!bytes || memchr(bytes, '\0', length)) return NULL;
  char *copy = malloc((size_t)length + 1);
  if (!copy) return NULL;
  memcpy(copy, bytes, length);
  copy[length] = '\0';
  return copy;
}

static ZjsValue host_send(
  ZjsContext *context,
  ZjsValue *arguments,
  uint32_t count
) {
  if (count != 2 ||
      !zjs_is_string(arguments[0]) ||
      !zjs_is_string(arguments[1]) ||
      !entered_engine) {
    ZjsValue message = zjs_new_string(
      context,
      "worker.send expects a channel and serialized payload",
      (uint32_t)(sizeof("worker.send expects a channel and serialized payload") - 1)
    );
    zjs_throw(context, message);
    return zjs_undefined();
  }

  uint32_t channel_length = 0;
  uint32_t payload_length = 0;
  const char *channel = zjs_string_bytes(arguments[0], &channel_length);
  const char *payload = zjs_string_bytes(arguments[1], &payload_length);
  char *channel_copy = copy_string_bytes(channel, channel_length);
  char *payload_copy = copy_string_bytes(payload, payload_length);
  if (!channel_copy || !payload_copy) {
    free(channel_copy);
    free(payload_copy);
    ZjsValue message = zjs_new_string(
      context,
      "worker.send could not copy its message",
      (uint32_t)(sizeof("worker.send could not copy its message") - 1)
    );
    zjs_throw(context, message);
    return zjs_undefined();
  }

  free(entered_engine->response_channel);
  free(entered_engine->response_payload);
  entered_engine->response_channel = channel_copy;
  entered_engine->response_payload = payload_copy;
  return zjs_undefined();
}

static void copy_error(ZappZjsEngine *engine, const char *fallback) {
  const char *message = fallback;
  uint32_t length = 0;
  if (engine->context && zjs_had_error(engine->context)) {
    ZjsValue error = zjs_get_error(engine->context);
    ZjsValue property = zjs_get_property(engine->context, error, "message");
    const char *bytes = zjs_is_string(property)
      ? zjs_string_bytes(property, &length)
      : zjs_string_bytes(error, &length);
    if (bytes) {
      size_t copied = length < sizeof(engine->error) - 1
        ? (size_t)length
        : sizeof(engine->error) - 1;
      memcpy(engine->error, bytes, copied);
      engine->error[copied] = '\0';
      return;
    }
  }
  snprintf(engine->error, sizeof(engine->error), "%s", message);
}

ZappZjsEngine *zapp_zjs_engine_create(void) {
  ZappZjsEngine *engine = calloc(1, sizeof(ZappZjsEngine));
  if (!engine) return NULL;
  engine->context = zjs_new_minimal_context();
  if (!engine->context) {
    free(engine);
    return NULL;
  }
  zjs_register_host_function(engine->context, "__zappWorkerSend", host_send);
  return engine;
}

int32_t zapp_zjs_engine_evaluate_module(
  ZappZjsEngine *engine,
  NSData *source,
  const char *module_name
) {
  if (!engine || !engine->context || !source || !module_name) return 1;
  engine->error[0] = '\0';
  if (engine->has_command_handler) {
    zjs_unroot(engine->context, engine->command_handle);
    engine->has_command_handler = 0;
  }

  ZappZjsEngine *previous_engine = entered_engine;
  entered_engine = engine;
  ZjsValue exports = zjs_eval_module_source(
    engine->context,
    (const char *)source.bytes,
    source.length,
    module_name
  );
  entered_engine = previous_engine;
  if (zjs_had_error(engine->context)) {
    copy_error(engine, "worker module evaluation failed");
    return 2;
  }

  ZjsValue command = zjs_get_property(engine->context, exports, "onMessage");
  if (!zjs_is_callable(command)) {
    copy_error(engine, "worker module must export callable onMessage");
    return 3;
  }
  engine->command_handle = zjs_root(engine->context, command);
  engine->has_command_handler = 1;
  return 0;
}

int32_t zapp_zjs_engine_dispatch(
  ZappZjsEngine *engine,
  const char *channel,
  const char *payload
) {
  if (!engine || !engine->context || !engine->has_command_handler ||
      !channel || !payload) return 1;
  ZjsValue command = zjs_root_get(engine->context, engine->command_handle);
  ZjsValue arguments[2] = {
    zjs_new_string(engine->context, channel, (uint32_t)strlen(channel)),
    zjs_new_string(engine->context, payload, (uint32_t)strlen(payload)),
  };
  ZappZjsEngine *previous_engine = entered_engine;
  entered_engine = engine;
  zjs_call(engine->context, command, zjs_undefined(), arguments, 2);
  entered_engine = previous_engine;
  if (zjs_had_error(engine->context)) {
    copy_error(engine, "worker command failed");
    return 2;
  }
  return 0;
}

int32_t zapp_zjs_engine_has_pending_work(ZappZjsEngine *engine) {
  return engine && engine->context
    ? zjs_has_pending_work(engine->context)
    : 0;
}

int64_t zapp_zjs_engine_next_wake_milliseconds(ZappZjsEngine *engine) {
  return engine && engine->context
    ? zjs_next_timer_ms(engine->context)
    : -1;
}

int32_t zapp_zjs_engine_pump(ZappZjsEngine *engine) {
  if (!engine || !engine->context) return 1;
  ZappZjsEngine *previous_engine = entered_engine;
  entered_engine = engine;
  zjs_run_pending_timers(engine->context);
  zjs_drain_microtasks(engine->context);
  entered_engine = previous_engine;
  if (zjs_had_error(engine->context)) {
    copy_error(engine, "worker event loop failed");
    return 2;
  }
  return 0;
}

int32_t zapp_zjs_engine_result(ZappZjsEngine *engine) {
  return engine && engine->context ? 0 : 1;
}

const char *zapp_zjs_engine_response_channel(ZappZjsEngine *engine) {
  return engine ? engine->response_channel : NULL;
}

const char *zapp_zjs_engine_response_payload(ZappZjsEngine *engine) {
  return engine ? engine->response_payload : NULL;
}

const char *zapp_zjs_engine_error(ZappZjsEngine *engine) {
  return engine && engine->error[0] != '\0' ? engine->error : NULL;
}

void zapp_zjs_engine_destroy(ZappZjsEngine *engine) {
  if (!engine) return;
  if (engine->context) {
    if (engine->has_command_handler) {
      zjs_unroot(engine->context, engine->command_handle);
    }
    zjs_free_context(engine->context);
  }
  free(engine->response_channel);
  free(engine->response_payload);
  free(engine);
}

static void sleep_one_millisecond(void) {
  const struct timespec duration = {
    .tv_sec = 0,
    .tv_nsec = 1000000,
  };
  nanosleep(&duration, NULL);
}

static void *run_worker(void *context) {
  ZappZjsWorker *worker = context;
  ZappZjsEngine *engine = zapp_zjs_engine_create();
  if (!engine) {
    worker->result = 100;
    return NULL;
  }

  NSData *source = (__bridge NSData *)worker->source;
  int32_t status = zapp_zjs_engine_evaluate_module(
    engine,
    source,
    worker->module_name
  );
  if (status != 0) {
    const char *error = zapp_zjs_engine_error(engine);
    fprintf(
      stderr,
      "application worker %s failed to load%s%s\n",
      worker->module_name,
      error ? ": " : "",
      error ? error : ""
    );
    fflush(stderr);
    worker->result = status;
    zapp_zjs_engine_destroy(engine);
    return NULL;
  }

  const char *ready = zapp_zjs_engine_response_channel(engine);
  if (ready) {
    fprintf(
      stdout,
      "application worker %s sent %s\n",
      worker->module_name,
      ready
    );
    fflush(stdout);
  }

  while (!atomic_load_explicit(
    &worker->cancellation_requested,
    memory_order_acquire
  )) {
    if (zapp_zjs_engine_has_pending_work(engine)) {
      status = zapp_zjs_engine_pump(engine);
      if (status != 0) {
        const char *error = zapp_zjs_engine_error(engine);
        fprintf(
          stderr,
          "application worker %s failed%s%s\n",
          worker->module_name,
          error ? ": " : "",
          error ? error : ""
        );
        fflush(stderr);
        worker->result = status;
        zapp_zjs_engine_destroy(engine);
        return NULL;
      }
    }
    sleep_one_millisecond();
  }

  worker->result = zapp_zjs_engine_result(engine);
  zapp_zjs_engine_destroy(engine);
  return NULL;
}

uintptr_t zapp_zjs_worker_start(
  NSData *source,
  const char *module_name
) {
  if (!source || !module_name) return 0;
  ZappZjsWorker *worker = calloc(1, sizeof(ZappZjsWorker));
  if (!worker) return 0;
  worker->runtime.cancel = cancel_worker_runtime;
  worker->runtime.join = join_worker_runtime;
  worker->runtime.destroy = destroy_worker_runtime;
  worker->source = (__bridge_retained void *)source;
  worker->module_name = strdup(module_name);
  if (!worker->module_name) {
    CFBridgingRelease(worker->source);
    free(worker);
    return 0;
  }
  atomic_init(&worker->cancellation_requested, 0);
  if (pthread_create(&worker->thread, NULL, run_worker, worker) != 0) {
    CFBridgingRelease(worker->source);
    free(worker->module_name);
    free(worker);
    return 0;
  }
  worker->started = 1;
  return (uintptr_t)worker;
}

void zapp_zjs_worker_cancel(uintptr_t identity) {
  ZappZjsWorker *worker = (ZappZjsWorker *)identity;
  if (!worker) return;
  atomic_store_explicit(
    &worker->cancellation_requested,
    1,
    memory_order_release
  );
}

int32_t zapp_zjs_worker_join(uintptr_t identity) {
  ZappZjsWorker *worker = (ZappZjsWorker *)identity;
  if (!worker) return 1;
  if (worker->started && !worker->joined) {
    if (pthread_join(worker->thread, NULL) != 0) return 2;
    worker->joined = 1;
  }
  return worker->result;
}

void zapp_zjs_worker_destroy(uintptr_t identity) {
  ZappZjsWorker *worker = (ZappZjsWorker *)identity;
  if (!worker) return;
  zapp_zjs_worker_cancel(identity);
  (void)zapp_zjs_worker_join(identity);
  CFBridgingRelease(worker->source);
  free(worker->module_name);
  free(worker);
}

static void cancel_worker_runtime(ZappWorkerRuntime *runtime) {
  zapp_zjs_worker_cancel((uintptr_t)runtime);
}

static int32_t join_worker_runtime(ZappWorkerRuntime *runtime) {
  return zapp_zjs_worker_join((uintptr_t)runtime);
}

static void destroy_worker_runtime(ZappWorkerRuntime *runtime) {
  zapp_zjs_worker_destroy((uintptr_t)runtime);
}
