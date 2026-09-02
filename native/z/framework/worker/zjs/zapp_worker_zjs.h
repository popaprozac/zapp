#ifndef ZAPP_WORKER_ZJS_ADAPTER_H
#define ZAPP_WORKER_ZJS_ADAPTER_H

#include <stddef.h>
#include <stdint.h>
#import <Foundation/Foundation.h>
#include "zapp_worker_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZappZjsEngine ZappZjsEngine;
typedef struct ZappZjsWorker ZappZjsWorker;

ZappZjsEngine *zapp_zjs_engine_create(void);
int32_t zapp_zjs_engine_evaluate_module(
  ZappZjsEngine *engine,
  NSData *source,
  const char *module_name
);
int32_t zapp_zjs_engine_dispatch(
  ZappZjsEngine *engine,
  const char *channel,
  const char *payload
);
int32_t zapp_zjs_engine_has_pending_work(ZappZjsEngine *engine);
int64_t zapp_zjs_engine_next_wake_milliseconds(ZappZjsEngine *engine);
int32_t zapp_zjs_engine_pump(ZappZjsEngine *engine);
int32_t zapp_zjs_engine_result(ZappZjsEngine *engine);
const char *zapp_zjs_engine_response_channel(ZappZjsEngine *engine);
const char *zapp_zjs_engine_response_payload(ZappZjsEngine *engine);
const char *zapp_zjs_engine_error(ZappZjsEngine *engine);
void zapp_zjs_engine_destroy(ZappZjsEngine *engine);

uintptr_t zapp_zjs_worker_start(
  NSData *source,
  const char *module_name
);
void zapp_zjs_worker_cancel(uintptr_t identity);
int32_t zapp_zjs_worker_dispatch(
  uintptr_t identity,
  const char *channel,
  const char *payload
);
int32_t zapp_zjs_worker_join(uintptr_t identity);
void zapp_zjs_worker_destroy(uintptr_t identity);

#ifdef __cplusplus
}
#endif

#endif
