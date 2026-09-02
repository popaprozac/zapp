#include "zapp_worker_zjs.h"

#include <zjs.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Implemented in Z and exported through its checked C ABI. The engine adapter
// deliberately knows only this stable host operation, not Z service internals.
extern int32_t zapp_worker_probe_add(int32_t left, int32_t right);

struct ZappZjsEngine {
  ZjsContext *context;
  uint32_t command_handle;
  int has_command_handler;
  char *response_channel;
  char *response_payload;
  int response_ready;
  char error[512];
};

// ZJS host functions do not currently carry embedder user data. Worker
// engines are thread-confined, so the adapter binds the engine being entered
// for the duration of each evaluation or pump. This remains safe when several
// engines share an OS thread because calls into an engine are synchronous.
static _Thread_local ZappZjsEngine *entered_engine;

static char *copy_string_bytes(const char *bytes, uint32_t length) {
  if (!bytes || memchr(bytes, '\0', length)) return NULL;
  char *copy = malloc((size_t) length + 1);
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
      (uint32_t) (
        sizeof("worker.send expects a channel and serialized payload") - 1
      )
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
      (uint32_t) (sizeof("worker.send could not copy its message") - 1)
    );
    zjs_throw(context, message);
    return zjs_undefined();
  }

  free(entered_engine->response_channel);
  free(entered_engine->response_payload);
  entered_engine->response_channel = channel_copy;
  entered_engine->response_payload = payload_copy;
  entered_engine->response_ready = 1;
  return zjs_undefined();
}

static ZjsValue host_add(
  ZjsContext *context,
  ZjsValue *arguments,
  uint32_t count
) {
  if (count != 2 ||
      !zjs_is_int32(arguments[0]) ||
      !zjs_is_int32(arguments[1])) {
    ZjsValue message = zjs_new_string(
      context,
      "service.add expects two i32 arguments",
      (uint32_t) (sizeof("service.add expects two i32 arguments") - 1)
    );
    zjs_throw(context, message);
    return zjs_undefined();
  }

  int32_t result = zapp_worker_probe_add(
    zjs_as_int32(arguments[0]),
    zjs_as_int32(arguments[1])
  );
  return zjs_int32(result);
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
        ? (size_t) length
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

  zjs_register_host_function(engine->context, "__zappServiceAdd", host_add);
  zjs_register_host_function(engine->context, "__zappWorkerSend", host_send);
  return engine;
}

int32_t zapp_zjs_engine_evaluate_module(
  ZappZjsEngine *engine,
  const char *source
) {
  if (!engine || !engine->context || !source) return 1;
  engine->error[0] = '\0';
  free(engine->response_channel);
  free(engine->response_payload);
  engine->response_channel = NULL;
  engine->response_payload = NULL;
  engine->response_ready = 0;
  if (engine->has_command_handler) {
    zjs_unroot(engine->context, engine->command_handle);
    engine->has_command_handler = 0;
  }

  ZappZjsEngine *previous_engine = entered_engine;
  entered_engine = engine;
  ZjsValue exports = zjs_eval_module_source(
    engine->context,
    source,
    strlen(source),
    "/zapp/internal/worker-proof.mjs"
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
    zjs_new_string(engine->context, channel, (uint32_t) strlen(channel)),
    zjs_new_string(engine->context, payload, (uint32_t) strlen(payload))
  };
  ZappZjsEngine *previous_engine = entered_engine;
  entered_engine = engine;
  zjs_call(
    engine->context,
    command,
    zjs_undefined(),
    arguments,
    2
  );
  entered_engine = previous_engine;
  if (zjs_had_error(engine->context)) {
    copy_error(engine, "worker command failed");
    return 2;
  }
  return 0;
}

int32_t zapp_zjs_engine_has_pending_work(ZappZjsEngine *engine) {
  if (!engine || !engine->context) return 0;
  return zjs_has_pending_work(engine->context);
}

int64_t zapp_zjs_engine_next_wake_milliseconds(ZappZjsEngine *engine) {
  if (!engine || !engine->context) return -1;
  return zjs_next_timer_ms(engine->context);
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

int32_t zapp_zjs_engine_is_complete(ZappZjsEngine *engine) {
  return engine ? engine->response_ready : 0;
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
  if (!engine || engine->error[0] == '\0') return NULL;
  return engine->error;
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
