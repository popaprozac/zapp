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
  ZappZjsWorkerServiceCallback service;
  ZappZjsWorker *worker;
  char *service_payload;
  int service_responded;
  int service_ok;
  int service_deferred;
  char error[512];
};

#define ZAPP_ZJS_WORKER_INBOX_CAPACITY 64
#define ZAPP_ZJS_WORKER_PENDING_SERVICE_CAPACITY 64

typedef enum ZappZjsWorkerMessageKind {
  ZAPP_ZJS_WORKER_MESSAGE_COMMAND = 0,
  ZAPP_ZJS_WORKER_MESSAGE_SERVICE_COMPLETION = 1,
} ZappZjsWorkerMessageKind;

typedef struct ZappZjsWorkerMessage {
  ZappZjsWorkerMessageKind kind;
  char *channel;
  char *payload;
  uint64_t request_id;
  int service_ok;
} ZappZjsWorkerMessage;

typedef struct ZappZjsPendingService {
  uint64_t request_id;
  uint32_t promise_handle;
  uint32_t resolve_handle;
  uint32_t reject_handle;
  int active;
} ZappZjsPendingService;

struct ZappZjsWorker {
  ZappWorkerRuntime runtime;
  pthread_t thread;
  _Atomic int cancellation_requested;
  _Atomic int finished;
  int started;
  int joined;
  int32_t result;
  uint64_t restart_max_retries;
  uint64_t restart_within_milliseconds;
  uint64_t restart_failures;
  uint64_t restart_window_started_milliseconds;
  uint64_t incarnation;
  void *source;
  char *worker_id;
  char *module_name;
  ZappZjsWorkerMessageCallback message;
  void *message_context;
  ZappZjsWorkerMessageRelease message_release;
  ZappZjsWorkerServiceCallback service;
  void *service_context;
  ZappZjsWorkerServiceRelease service_release;
  ZappZjsWorkerServiceCancelCallback service_cancel;
  void *service_cancel_context;
  ZappZjsWorkerServiceCancelRelease service_cancel_release;
  pthread_mutex_t inbox_mutex;
  pthread_cond_t inbox_condition;
  ZappZjsWorkerMessage inbox[ZAPP_ZJS_WORKER_INBOX_CAPACITY];
  size_t inbox_head;
  size_t inbox_tail;
  size_t inbox_count;
  ZappZjsPendingService pending_services[
    ZAPP_ZJS_WORKER_PENDING_SERVICE_CAPACITY
  ];
};

static _Atomic uint64_t next_service_request_id = 1;

static void cancel_worker_runtime(ZappWorkerRuntime *runtime);
static int32_t dispatch_worker_runtime(
  ZappWorkerRuntime *runtime,
  const char *channel,
  const char *payload
);
static int32_t complete_worker_service_runtime(
  ZappWorkerRuntime *runtime,
  uint64_t request_id,
  int32_t ok,
  const char *payload
);
static int32_t join_worker_runtime(ZappWorkerRuntime *runtime);
static void destroy_worker_runtime(ZappWorkerRuntime *runtime);
static int32_t push_service_completion(
  ZappZjsWorker *worker,
  uint64_t request_id,
  int ok,
  const char *payload
);

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

static void clear_engine_response(ZappZjsEngine *engine) {
  free(engine->response_channel);
  free(engine->response_payload);
  engine->response_channel = NULL;
  engine->response_payload = NULL;
}

static void clear_service_response(ZappZjsEngine *engine) {
  free(engine->service_payload);
  engine->service_payload = NULL;
  engine->service_responded = 0;
  engine->service_ok = 0;
  engine->service_deferred = 0;
}

static void throw_service_payload(
  ZjsContext *context,
  const char *payload
) {
  const char *source = payload ? payload : "application worker service invocation failed";
  ZjsValue message = zjs_new_string(
    context,
    source,
    (uint32_t)strlen(source)
  );
  zjs_throw(context, message);
}

static const char *stringify_service_arguments(
  ZjsContext *context,
  ZjsValue value,
  char **owned
) {
  *owned = NULL;
  if (zjs_is_undefined(value) || zjs_is_null(value)) return "null";
  ZjsValue json = zjs_get_global(context, "JSON");
  ZjsValue stringify = zjs_get_property(context, json, "stringify");
  zjs_pin(context, stringify);
  ZjsValue serialized = zjs_call(
    context,
    stringify,
    json,
    &value,
    1
  );
  zjs_unpin(context);
  if (zjs_had_error(context) || !zjs_is_string(serialized)) return NULL;
  uint32_t length = 0;
  const char *bytes = zjs_string_bytes(serialized, &length);
  *owned = copy_string_bytes(bytes, length);
  return *owned;
}

static ZjsValue parse_service_result(
  ZjsContext *context,
  const char *payload
) {
  ZjsValue json = zjs_get_global(context, "JSON");
  ZjsValue parse = zjs_get_property(context, json, "parse");
  zjs_pin(context, parse);
  ZjsValue source = zjs_new_string(
    context,
    payload,
    (uint32_t)strlen(payload)
  );
  zjs_pin(context, source);
  ZjsValue parsed = zjs_call(context, parse, json, &source, 1);
  zjs_unpin(context);
  zjs_unpin(context);
  return parsed;
}

static ZappZjsPendingService *find_pending_service(
  ZappZjsWorker *worker,
  uint64_t request_id
) {
  for (size_t index = 0;
       index < ZAPP_ZJS_WORKER_PENDING_SERVICE_CAPACITY;
       index += 1) {
    ZappZjsPendingService *pending = &worker->pending_services[index];
    if (pending->active && pending->request_id == request_id) return pending;
  }
  return NULL;
}

static ZappZjsPendingService *reserve_pending_service(
  ZappZjsWorker *worker,
  uint64_t request_id
) {
  for (size_t index = 0;
       index < ZAPP_ZJS_WORKER_PENDING_SERVICE_CAPACITY;
       index += 1) {
    ZappZjsPendingService *pending = &worker->pending_services[index];
    if (pending->active) continue;
    *pending = (ZappZjsPendingService){
      .request_id = request_id,
      .active = 1,
    };
    return pending;
  }
  return NULL;
}

static void release_pending_service(
  ZappZjsEngine *engine,
  ZappZjsPendingService *pending
) {
  if (!engine || !pending || !pending->active) return;
  zjs_unroot(engine->context, pending->promise_handle);
  zjs_unroot(engine->context, pending->resolve_handle);
  zjs_unroot(engine->context, pending->reject_handle);
  *pending = (ZappZjsPendingService){0};
}

static ZjsValue create_pending_service_promise(
  ZappZjsEngine *engine,
  uint64_t request_id
) {
  ZjsContext *context = engine->context;
  ZappZjsPendingService *pending = reserve_pending_service(
    engine->worker,
    request_id
  );
  if (!pending) {
    if (engine->worker->service_cancel) {
      engine->worker->service_cancel(
        request_id,
        engine->worker->service_cancel_context
      );
    }
    throw_service_payload(
      context,
      "application worker has too many pending service calls"
    );
    return zjs_undefined();
  }

  ZjsValue constructor = zjs_get_global(context, "Promise");
  zjs_pin(context, constructor);
  ZjsValue with_resolvers = zjs_get_property(
    context,
    constructor,
    "withResolvers"
  );
  zjs_pin(context, with_resolvers);
  ZjsValue capability = zjs_call(
    context,
    with_resolvers,
    constructor,
    NULL,
    0
  );
  zjs_unpin(context);
  zjs_unpin(context);
  if (zjs_had_error(context) || !zjs_is_object(capability)) {
    *pending = (ZappZjsPendingService){0};
    return zjs_undefined();
  }

  zjs_pin(context, capability);
  ZjsValue promise = zjs_get_property(context, capability, "promise");
  zjs_pin(context, promise);
  pending->promise_handle = zjs_root(context, promise);
  ZjsValue resolve = zjs_get_property(context, capability, "resolve");
  pending->resolve_handle = zjs_root(context, resolve);
  ZjsValue reject = zjs_get_property(context, capability, "reject");
  pending->reject_handle = zjs_root(context, reject);
  zjs_set_property(
    context,
    promise,
    "__zappRequestId",
    zjs_double((double)request_id)
  );
  zjs_unpin(context);
  zjs_unpin(context);
  return promise;
}

static int32_t settle_pending_service(
  ZappZjsEngine *engine,
  uint64_t request_id,
  int ok,
  const char *payload
) {
  ZappZjsPendingService *pending = find_pending_service(
    engine->worker,
    request_id
  );
  if (!pending) return 1;

  // Promise callbacks may invoke Zapp host functions while the microtask
  // queue drains. Re-enter the owning engine just as module evaluation,
  // command dispatch, and timer pumping do; the worker thread remains the
  // sole owner of this context throughout settlement.
  ZappZjsEngine *previous_engine = entered_engine;
  entered_engine = engine;

  ZjsValue callback = zjs_root_get(
    engine->context,
    ok ? pending->resolve_handle : pending->reject_handle
  );
  ZjsValue value = ok
    ? parse_service_result(engine->context, payload)
    : zjs_new_string(
        engine->context,
        payload,
        (uint32_t)strlen(payload)
      );
  zjs_call(
    engine->context,
    callback,
    zjs_undefined(),
    &value,
    1
  );
  release_pending_service(engine, pending);
  zjs_drain_microtasks(engine->context);
  int32_t status = zjs_had_error(engine->context) ? 2 : 0;
  entered_engine = previous_engine;
  return status;
}

static void cancel_and_release_all_pending_services(ZappZjsEngine *engine) {
  if (!engine || !engine->worker) return;
  for (size_t index = 0;
       index < ZAPP_ZJS_WORKER_PENDING_SERVICE_CAPACITY;
       index += 1) {
    ZappZjsPendingService *pending = &engine->worker->pending_services[index];
    if (pending->active && engine->worker->service_cancel) {
      engine->worker->service_cancel(
        pending->request_id,
        engine->worker->service_cancel_context
      );
    }
    release_pending_service(
      engine,
      pending
    );
  }
}

static ZjsValue host_invoke_service(
  ZjsContext *context,
  ZjsValue *arguments,
  uint32_t count
) {
  ZappZjsEngine *engine = entered_engine;
  if (!engine || !engine->service || count < 1 ||
      !zjs_is_string(arguments[0])) {
    throw_service_payload(
      context,
      "application worker service bridge is unavailable"
    );
    return zjs_undefined();
  }
  uint32_t method_length = 0;
  const char *method_bytes = zjs_string_bytes(arguments[0], &method_length);
  char *method = copy_string_bytes(method_bytes, method_length);
  if (!method) {
    throw_service_payload(context, "application worker could not copy the service method");
    return zjs_undefined();
  }
  char *owned_serialized = NULL;
  const char *serialized = stringify_service_arguments(
    context,
    count > 1 ? arguments[1] : zjs_undefined(),
    &owned_serialized
  );
  if (!serialized) {
    free(method);
    if (!zjs_had_error(context)) {
      throw_service_payload(context, "application worker could not serialize service arguments");
    }
    return zjs_undefined();
  }

  clear_service_response(engine);
  uint64_t request_id = atomic_fetch_add_explicit(
    &next_service_request_id,
    1,
    memory_order_relaxed
  );
  engine->service(
    (uintptr_t)engine->worker,
    request_id,
    method,
    serialized,
    engine->worker->service_context
  );
  free(method);
  free(owned_serialized);
  if (engine->service_deferred) {
    return create_pending_service_promise(engine, request_id);
  }
  if (!engine->service_responded || !engine->service_payload) {
    throw_service_payload(context, "application worker service produced no response");
    return zjs_undefined();
  }
  if (!engine->service_ok) {
    throw_service_payload(context, engine->service_payload);
    return zjs_undefined();
  }
  return parse_service_result(context, engine->service_payload);
}

static ZjsValue host_cancel_service(
  ZjsContext *context,
  ZjsValue *arguments,
  uint32_t count
) {
  ZappZjsEngine *engine = entered_engine;
  if (!engine || !engine->worker || count != 1 ||
      !zjs_is_number(arguments[0])) {
    return zjs_bool(0);
  }
  double numeric_id = zjs_is_int32(arguments[0])
    ? (double)zjs_as_int32(arguments[0])
    : zjs_as_double(arguments[0]);
  if (numeric_id <= 0) return zjs_bool(0);
  uint64_t request_id = (uint64_t)numeric_id;
  ZappZjsPendingService *pending = find_pending_service(
    engine->worker,
    request_id
  );
  if (!pending) return zjs_bool(0);
  if (engine->worker->service_cancel) {
    engine->worker->service_cancel(
      request_id,
      engine->worker->service_cancel_context
    );
  }
  settle_pending_service(
    engine,
    request_id,
    0,
    "The operation was aborted"
  );
  return zjs_bool(1);
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

  if (entered_engine->worker && entered_engine->worker->message) {
    entered_engine->worker->message(
      entered_engine->worker->worker_id,
      channel_copy,
      payload_copy,
      entered_engine->worker->message_context
    );
    fprintf(
      stdout,
      "application worker %s sent %s\n",
      entered_engine->worker->module_name,
      channel_copy
    );
    fflush(stdout);
    free(channel_copy);
    free(payload_copy);
    return zjs_undefined();
  }

  clear_engine_response(entered_engine);
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
  ZjsValue bridge = zjs_new_object(engine->context);
  ZjsValue invoke = zjs_register_host_function(
    engine->context,
    "__zappWorkerInvokeService",
    host_invoke_service
  );
  ZjsValue cancel_service = zjs_register_host_function(
    engine->context,
    "__zappWorkerCancelService",
    host_cancel_service
  );
  zjs_set_property(engine->context, bridge, "invokeService", invoke);
  zjs_set_property(
    engine->context,
    bridge,
    "cancelService",
    cancel_service
  );
  zjs_set_global(engine->context, "__zappBridge", bridge);
  ZjsValue global = zjs_get_global(engine->context, "globalThis");
  zjs_set_property(engine->context, global, "__zappBridge", bridge);
  zjs_set_property(
    engine->context,
    global,
    "__zappWorkerInvokeService",
    invoke
  );
  zjs_set_property(
    engine->context,
    global,
    "__zappWorkerCancelService",
    cancel_service
  );
  return engine;
}

int32_t zapp_zjs_worker_service_respond(
  int32_t ok,
  const char *payload
) {
  if (!entered_engine || !payload) return 1;
  char *copy = strdup(payload);
  if (!copy) return 2;
  clear_service_response(entered_engine);
  entered_engine->service_payload = copy;
  entered_engine->service_responded = 1;
  entered_engine->service_ok = ok != 0;
  return 0;
}

int32_t zapp_zjs_worker_service_defer(void) {
  if (!entered_engine) return 1;
  entered_engine->service_deferred = 1;
  return 0;
}

int32_t zapp_zjs_worker_service_complete(
  uintptr_t identity,
  uint64_t request_id,
  int32_t ok,
  const char *payload
) {
  ZappZjsWorker *worker = (ZappZjsWorker *)identity;
  if (!worker || request_id == 0 || !payload) return 1;
  return push_service_completion(worker, request_id, ok, payload);
}

int32_t zapp_zjs_engine_evaluate_module(
  ZappZjsEngine *engine,
  NSData *source,
  const char *module_name
) {
  if (!engine || !engine->context || !source || !module_name) return 1;
  engine->error[0] = '\0';
  clear_engine_response(engine);
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
  clear_engine_response(engine);
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
    cancel_and_release_all_pending_services(engine);
    if (engine->has_command_handler) {
      zjs_unroot(engine->context, engine->command_handle);
    }
    zjs_free_context(engine->context);
  }
  clear_engine_response(engine);
  clear_service_response(engine);
  free(engine);
}

static void destroy_worker_message(ZappZjsWorkerMessage *message) {
  free(message->channel);
  free(message->payload);
  message->channel = NULL;
  message->payload = NULL;
}

static int32_t push_worker_message(
  ZappZjsWorker *worker,
  const char *channel,
  const char *payload
) {
  char *channel_copy = strdup(channel);
  char *payload_copy = strdup(payload);
  if (!channel_copy || !payload_copy) {
    free(channel_copy);
    free(payload_copy);
    return 2;
  }

  pthread_mutex_lock(&worker->inbox_mutex);
  if (atomic_load_explicit(
        &worker->cancellation_requested,
        memory_order_acquire
      ) || atomic_load_explicit(
        &worker->finished,
        memory_order_acquire
      )) {
    pthread_mutex_unlock(&worker->inbox_mutex);
    free(channel_copy);
    free(payload_copy);
    return 3;
  }
  if (worker->inbox_count == ZAPP_ZJS_WORKER_INBOX_CAPACITY) {
    pthread_mutex_unlock(&worker->inbox_mutex);
    free(channel_copy);
    free(payload_copy);
    return 4;
  }
  ZappZjsWorkerMessage *message = &worker->inbox[worker->inbox_tail];
  message->kind = ZAPP_ZJS_WORKER_MESSAGE_COMMAND;
  message->channel = channel_copy;
  message->payload = payload_copy;
  worker->inbox_tail = (
    worker->inbox_tail + 1
  ) % ZAPP_ZJS_WORKER_INBOX_CAPACITY;
  worker->inbox_count += 1;
  pthread_cond_signal(&worker->inbox_condition);
  pthread_mutex_unlock(&worker->inbox_mutex);
  return 0;
}

static int32_t push_service_completion(
  ZappZjsWorker *worker,
  uint64_t request_id,
  int ok,
  const char *payload
) {
  char *payload_copy = strdup(payload);
  if (!payload_copy) return 2;

  pthread_mutex_lock(&worker->inbox_mutex);
  if (atomic_load_explicit(
        &worker->cancellation_requested,
        memory_order_acquire
      ) || atomic_load_explicit(
        &worker->finished,
        memory_order_acquire
      )) {
    pthread_mutex_unlock(&worker->inbox_mutex);
    free(payload_copy);
    return 3;
  }
  if (worker->inbox_count == ZAPP_ZJS_WORKER_INBOX_CAPACITY) {
    pthread_mutex_unlock(&worker->inbox_mutex);
    free(payload_copy);
    return 4;
  }
  ZappZjsWorkerMessage *message = &worker->inbox[worker->inbox_tail];
  *message = (ZappZjsWorkerMessage){
    .kind = ZAPP_ZJS_WORKER_MESSAGE_SERVICE_COMPLETION,
    .payload = payload_copy,
    .request_id = request_id,
    .service_ok = ok != 0,
  };
  worker->inbox_tail = (
    worker->inbox_tail + 1
  ) % ZAPP_ZJS_WORKER_INBOX_CAPACITY;
  worker->inbox_count += 1;
  pthread_cond_signal(&worker->inbox_condition);
  pthread_mutex_unlock(&worker->inbox_mutex);
  return 0;
}

static int pop_worker_message(
  ZappZjsWorker *worker,
  ZappZjsWorkerMessage *message
) {
  pthread_mutex_lock(&worker->inbox_mutex);
  if (worker->inbox_count == 0) {
    pthread_mutex_unlock(&worker->inbox_mutex);
    return 0;
  }
  *message = worker->inbox[worker->inbox_head];
  worker->inbox[worker->inbox_head] = (ZappZjsWorkerMessage){0};
  worker->inbox_head = (
    worker->inbox_head + 1
  ) % ZAPP_ZJS_WORKER_INBOX_CAPACITY;
  worker->inbox_count -= 1;
  pthread_mutex_unlock(&worker->inbox_mutex);
  return 1;
}

static void wait_for_worker_work(
  ZappZjsWorker *worker,
  int64_t wake_milliseconds
) {
  if (wake_milliseconds == 0) return;
  pthread_mutex_lock(&worker->inbox_mutex);
  if (worker->inbox_count == 0 && !atomic_load_explicit(
        &worker->cancellation_requested,
        memory_order_acquire
      )) {
    if (wake_milliseconds < 0) {
      pthread_cond_wait(&worker->inbox_condition, &worker->inbox_mutex);
    } else {
      struct timespec deadline;
      clock_gettime(CLOCK_REALTIME, &deadline);
      deadline.tv_sec += wake_milliseconds / 1000;
      deadline.tv_nsec += (wake_milliseconds % 1000) * 1000000;
      if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000;
      }
      pthread_cond_timedwait(
        &worker->inbox_condition,
        &worker->inbox_mutex,
        &deadline
      );
    }
  }
  pthread_mutex_unlock(&worker->inbox_mutex);
}

static void deliver_engine_response(
  ZappZjsWorker *worker,
  ZappZjsEngine *engine
) {
  const char *channel = zapp_zjs_engine_response_channel(engine);
  const char *payload = zapp_zjs_engine_response_payload(engine);
  if (channel && payload && worker->message) {
    worker->message(
      worker->worker_id,
      channel,
      payload,
      worker->message_context
    );
    fprintf(
      stdout,
      "application worker %s sent %s\n",
      worker->module_name,
      channel
    );
    fflush(stdout);
  }
  clear_engine_response(engine);
}

static uint64_t worker_monotonic_milliseconds(void) {
  struct timespec current;
  if (clock_gettime(CLOCK_MONOTONIC, &current) != 0) return 0;
  return (uint64_t)current.tv_sec * 1000u
    + (uint64_t)current.tv_nsec / 1000000u;
}

// Returns 0 when restart is disabled, 1 when another incarnation is allowed,
// and 2 once the configured retry cap is exhausted. This preserves the
// established Zapp policy: maxRetries counts replacement incarnations, and a
// failure outside the current time window begins a fresh retry window.
static int record_worker_failure(ZappZjsWorker *worker) {
  if (!worker || worker->restart_max_retries == 0) return 0;
  uint64_t now = worker_monotonic_milliseconds();
  if (worker->restart_failures == 0 ||
      now < worker->restart_window_started_milliseconds ||
      now - worker->restart_window_started_milliseconds >
        worker->restart_within_milliseconds) {
    worker->restart_failures = 1;
    worker->restart_window_started_milliseconds = now;
  } else {
    worker->restart_failures += 1;
  }
  return worker->restart_failures > worker->restart_max_retries ? 2 : 1;
}

static void copy_worker_failure(
  ZappZjsEngine *engine,
  const char *fallback,
  char *destination,
  size_t capacity
) {
  const char *error = engine ? zapp_zjs_engine_error(engine) : NULL;
  snprintf(
    destination,
    capacity,
    "%s",
    error && error[0] != '\0' ? error : fallback
  );
}

static int32_t run_worker_incarnation(
  ZappZjsWorker *worker,
  char *failure,
  size_t failure_capacity
) {
  ZappZjsEngine *engine = zapp_zjs_engine_create();
  if (!engine) {
    copy_worker_failure(
      NULL,
      "worker engine allocation failed",
      failure,
      failure_capacity
    );
    return 100;
  }
  engine->service = worker->service;
  engine->worker = worker;

  NSData *source = (__bridge NSData *)worker->source;
  int32_t status = zapp_zjs_engine_evaluate_module(
    engine,
    source,
    worker->module_name
  );
  if (status != 0) {
    copy_worker_failure(
      engine,
      "worker module evaluation failed",
      failure,
      failure_capacity
    );
    zapp_zjs_engine_destroy(engine);
    return status;
  }

  deliver_engine_response(worker, engine);

  while (!atomic_load_explicit(
    &worker->cancellation_requested,
    memory_order_acquire
  )) {
    ZappZjsWorkerMessage message = {0};
    while (pop_worker_message(worker, &message)) {
      if (message.kind == ZAPP_ZJS_WORKER_MESSAGE_SERVICE_COMPLETION) {
        status = settle_pending_service(
          engine,
          message.request_id,
          message.service_ok,
          message.payload
        );
        destroy_worker_message(&message);
        // A cancelled Promise or an earlier incarnation has already released
        // this continuation. Its late Z completion is intentionally ignored.
        if (status == 1) continue;
        if (status != 0) {
          copy_error(engine, "worker service continuation failed");
          copy_worker_failure(
            engine,
            "worker service continuation failed",
            failure,
            failure_capacity
          );
          zapp_zjs_engine_destroy(engine);
          return status;
        }
        deliver_engine_response(worker, engine);
        continue;
      }
      status = zapp_zjs_engine_dispatch(
        engine,
        message.channel,
        message.payload
      );
      destroy_worker_message(&message);
      if (status != 0) {
        copy_worker_failure(
          engine,
          "worker rejected a message",
          failure,
          failure_capacity
        );
        zapp_zjs_engine_destroy(engine);
        return status;
      }
      deliver_engine_response(worker, engine);
    }

    if (zapp_zjs_engine_has_pending_work(engine)) {
      status = zapp_zjs_engine_pump(engine);
      if (status != 0) {
        copy_worker_failure(
          engine,
          "worker event loop failed",
          failure,
          failure_capacity
        );
        zapp_zjs_engine_destroy(engine);
        return status;
      }
      deliver_engine_response(worker, engine);
    }
    wait_for_worker_work(
      worker,
      zapp_zjs_engine_next_wake_milliseconds(engine)
    );
  }

  status = zapp_zjs_engine_result(engine);
  zapp_zjs_engine_destroy(engine);
  return status;
}

static void *run_worker(void *context) {
  ZappZjsWorker *worker = context;
  int32_t status = 0;
  while (!atomic_load_explicit(
    &worker->cancellation_requested,
    memory_order_acquire
  )) {
    worker->incarnation += 1;
    char failure[512] = {0};
    status = run_worker_incarnation(worker, failure, sizeof(failure));
    if (atomic_load_explicit(
      &worker->cancellation_requested,
      memory_order_acquire
    )) break;

    fprintf(
      stderr,
      "application worker %s incarnation %llu failed: %s\n",
      worker->module_name,
      (unsigned long long)worker->incarnation,
      failure[0] != '\0' ? failure : "unknown worker failure"
    );
    int decision = record_worker_failure(worker);
    if (decision == 1) {
      fprintf(
        stderr,
        "application worker %s restarting as incarnation %llu "
        "(retry %llu/%llu in %llums)\n",
        worker->module_name,
        (unsigned long long)(worker->incarnation + 1),
        (unsigned long long)worker->restart_failures,
        (unsigned long long)worker->restart_max_retries,
        (unsigned long long)worker->restart_within_milliseconds
      );
      fflush(stderr);
      continue;
    }
    if (decision == 2) {
      fprintf(
        stderr,
        "application worker %s gave up after %llu retries\n",
        worker->module_name,
        (unsigned long long)worker->restart_max_retries
      );
    }
    fflush(stderr);
    break;
  }

  worker->result = status;
  atomic_store_explicit(&worker->finished, 1, memory_order_release);
  return NULL;
}

uintptr_t zapp_zjs_worker_start(
  NSData *source,
  const char *worker_id,
  const char *module_name,
  int32_t restart_enabled,
  uint64_t restart_max_retries,
  uint64_t restart_within_milliseconds,
  ZappZjsWorkerMessageCallback message,
  void *context,
  ZappZjsWorkerMessageRelease release,
  ZappZjsWorkerServiceCallback service,
  void *service_context,
  ZappZjsWorkerServiceRelease service_release,
  ZappZjsWorkerServiceCancelCallback service_cancel,
  void *service_cancel_context,
  ZappZjsWorkerServiceCancelRelease service_cancel_release
) {
  if (!source || !worker_id || !module_name || !message || !release ||
      !service || !service_release || !service_cancel ||
      !service_cancel_release) {
    if (release) release(context);
    if (service_release) service_release(service_context);
    if (service_cancel_release) {
      service_cancel_release(service_cancel_context);
    }
    return 0;
  }
  ZappZjsWorker *worker = calloc(1, sizeof(ZappZjsWorker));
  if (!worker) {
    release(context);
    service_release(service_context);
    service_cancel_release(service_cancel_context);
    return 0;
  }
  worker->runtime.cancel = cancel_worker_runtime;
  worker->runtime.dispatch = dispatch_worker_runtime;
  worker->runtime.complete_service = complete_worker_service_runtime;
  worker->runtime.join = join_worker_runtime;
  worker->runtime.destroy = destroy_worker_runtime;
  worker->message = message;
  worker->message_context = context;
  worker->message_release = release;
  worker->service = service;
  worker->service_context = service_context;
  worker->service_release = service_release;
  worker->service_cancel = service_cancel;
  worker->service_cancel_context = service_cancel_context;
  worker->service_cancel_release = service_cancel_release;
  worker->restart_max_retries = restart_enabled != 0
    ? restart_max_retries
    : 0;
  worker->restart_within_milliseconds = restart_enabled != 0
    ? restart_within_milliseconds
    : 0;
  worker->source = (__bridge_retained void *)source;
  worker->worker_id = strdup(worker_id);
  worker->module_name = strdup(module_name);
  if (!worker->worker_id || !worker->module_name ||
      pthread_mutex_init(&worker->inbox_mutex, NULL) != 0) {
    CFBridgingRelease(worker->source);
    free(worker->worker_id);
    free(worker->module_name);
    worker->message_release(worker->message_context);
    worker->service_release(worker->service_context);
    worker->service_cancel_release(worker->service_cancel_context);
    free(worker);
    return 0;
  }
  if (pthread_cond_init(&worker->inbox_condition, NULL) != 0) {
    pthread_mutex_destroy(&worker->inbox_mutex);
    CFBridgingRelease(worker->source);
    free(worker->worker_id);
    free(worker->module_name);
    worker->message_release(worker->message_context);
    worker->service_release(worker->service_context);
    worker->service_cancel_release(worker->service_cancel_context);
    free(worker);
    return 0;
  }
  atomic_init(&worker->cancellation_requested, 0);
  atomic_init(&worker->finished, 0);
  if (pthread_create(&worker->thread, NULL, run_worker, worker) != 0) {
    pthread_cond_destroy(&worker->inbox_condition);
    pthread_mutex_destroy(&worker->inbox_mutex);
    CFBridgingRelease(worker->source);
    free(worker->worker_id);
    free(worker->module_name);
    worker->message_release(worker->message_context);
    worker->service_release(worker->service_context);
    worker->service_cancel_release(worker->service_cancel_context);
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
  pthread_mutex_lock(&worker->inbox_mutex);
  pthread_cond_signal(&worker->inbox_condition);
  pthread_mutex_unlock(&worker->inbox_mutex);
}

int32_t zapp_zjs_worker_dispatch(
  uintptr_t identity,
  const char *channel,
  const char *payload
) {
  ZappZjsWorker *worker = (ZappZjsWorker *)identity;
  if (!worker || !channel || !payload) return 1;
  return push_worker_message(worker, channel, payload);
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
  for (size_t index = 0; index < ZAPP_ZJS_WORKER_INBOX_CAPACITY; index += 1) {
    destroy_worker_message(&worker->inbox[index]);
  }
  pthread_cond_destroy(&worker->inbox_condition);
  pthread_mutex_destroy(&worker->inbox_mutex);
  CFBridgingRelease(worker->source);
  free(worker->worker_id);
  free(worker->module_name);
  worker->message_release(worker->message_context);
  worker->service_release(worker->service_context);
  worker->service_cancel_release(worker->service_cancel_context);
  free(worker);
}

static void cancel_worker_runtime(ZappWorkerRuntime *runtime) {
  zapp_zjs_worker_cancel((uintptr_t)runtime);
}

static int32_t dispatch_worker_runtime(
  ZappWorkerRuntime *runtime,
  const char *channel,
  const char *payload
) {
  return zapp_zjs_worker_dispatch((uintptr_t)runtime, channel, payload);
}

static int32_t complete_worker_service_runtime(
  ZappWorkerRuntime *runtime,
  uint64_t request_id,
  int32_t ok,
  const char *payload
) {
  return push_service_completion(
    (ZappZjsWorker *)runtime,
    request_id,
    ok,
    payload
  );
}

static int32_t join_worker_runtime(ZappWorkerRuntime *runtime) {
  return zapp_zjs_worker_join((uintptr_t)runtime);
}

static void destroy_worker_runtime(ZappWorkerRuntime *runtime) {
  zapp_zjs_worker_destroy((uintptr_t)runtime);
}
