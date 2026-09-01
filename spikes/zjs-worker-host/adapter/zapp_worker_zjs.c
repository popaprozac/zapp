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
  int32_t result;
  char error[512];
};

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

  return zjs_int32(zapp_worker_probe_add(
    zjs_as_int32(arguments[0]),
    zjs_as_int32(arguments[1])
  ));
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

  ZjsValue exports = zjs_eval_module_source(
    engine->context,
    source,
    strlen(source),
    "/zapp/internal/worker-proof.mjs"
  );
  if (zjs_had_error(engine->context)) {
    copy_error(engine, "worker module evaluation failed");
    return 2;
  }

  ZjsValue result = zjs_get_property(engine->context, exports, "result");
  if (!zjs_is_int32(result)) {
    copy_error(engine, "worker module did not export an i32 result");
    return 3;
  }

  engine->result = zjs_as_int32(result);
  return 0;
}

int32_t zapp_zjs_engine_result(ZappZjsEngine *engine) {
  return engine ? engine->result : 0;
}

const char *zapp_zjs_engine_error(ZappZjsEngine *engine) {
  if (!engine || engine->error[0] == '\0') return NULL;
  return engine->error;
}

void zapp_zjs_engine_destroy(ZappZjsEngine *engine) {
  if (!engine) return;
  if (engine->context) zjs_free_context(engine->context);
  free(engine);
}
