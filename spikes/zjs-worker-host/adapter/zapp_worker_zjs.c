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
  int32_t result;
  int result_ready;
  char error[512];
};

// ZJS host functions do not currently carry embedder user data. Worker
// engines are thread-confined, so the adapter binds the engine being entered
// for the duration of each evaluation or pump. This remains safe when several
// engines share an OS thread because calls into an engine are synchronous.
static _Thread_local ZappZjsEngine *entered_engine;

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
  if (entered_engine) {
    entered_engine->result = result;
    entered_engine->result_ready = 1;
  }
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
  return engine;
}

int32_t zapp_zjs_engine_evaluate_module(
  ZappZjsEngine *engine,
  const char *source
) {
  if (!engine || !engine->context || !source) return 1;
  engine->error[0] = '\0';
  engine->result = 0;
  engine->result_ready = 0;
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

  ZjsValue command = zjs_get_property(engine->context, exports, "onCommand");
  if (!zjs_is_callable(command)) {
    copy_error(engine, "worker module must export callable onCommand");
    return 3;
  }
  engine->command_handle = zjs_root(engine->context, command);
  engine->has_command_handler = 1;

  return 0;
}

int32_t zapp_zjs_engine_dispatch(
  ZappZjsEngine *engine,
  int32_t left,
  int32_t right
) {
  if (!engine || !engine->context || !engine->has_command_handler) return 1;
  ZjsValue command = zjs_root_get(engine->context, engine->command_handle);
  ZjsValue arguments[2] = { zjs_int32(left), zjs_int32(right) };
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
  return engine ? engine->result_ready : 0;
}

int32_t zapp_zjs_engine_result(ZappZjsEngine *engine) {
  if (!engine || !engine->context) return 0;
  return engine->result;
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
  free(engine);
}
