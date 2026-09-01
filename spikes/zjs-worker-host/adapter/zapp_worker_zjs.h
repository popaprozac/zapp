#ifndef ZAPP_WORKER_ZJS_ADAPTER_H
#define ZAPP_WORKER_ZJS_ADAPTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct ZappZjsEngine ZappZjsEngine;

ZappZjsEngine *zapp_zjs_engine_create(void);
int32_t zapp_zjs_engine_evaluate_module(
  ZappZjsEngine *engine,
  const char *source
);
int32_t zapp_zjs_engine_has_pending_work(ZappZjsEngine *engine);
int64_t zapp_zjs_engine_next_wake_milliseconds(ZappZjsEngine *engine);
int32_t zapp_zjs_engine_pump(ZappZjsEngine *engine);
int32_t zapp_zjs_engine_result(ZappZjsEngine *engine);
const char *zapp_zjs_engine_error(ZappZjsEngine *engine);
void zapp_zjs_engine_destroy(ZappZjsEngine *engine);

#ifdef __cplusplus
}
#endif

#endif
