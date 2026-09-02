#ifndef ZAPP_WORKER_RUNTIME_H
#define ZAPP_WORKER_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZappWorkerRuntime ZappWorkerRuntime;

struct ZappWorkerRuntime {
  void (*cancel)(ZappWorkerRuntime *runtime);
  int32_t (*dispatch)(
    ZappWorkerRuntime *runtime,
    const char *channel,
    const char *payload
  );
  int32_t (*join)(ZappWorkerRuntime *runtime);
  void (*destroy)(ZappWorkerRuntime *runtime);
};

static inline void zapp_worker_runtime_cancel(uintptr_t identity) {
  ZappWorkerRuntime *runtime = (ZappWorkerRuntime *)identity;
  if (runtime && runtime->cancel) runtime->cancel(runtime);
}

static inline int32_t zapp_worker_runtime_dispatch(
  uintptr_t identity,
  const char *channel,
  const char *payload
) {
  ZappWorkerRuntime *runtime = (ZappWorkerRuntime *)identity;
  return runtime && runtime->dispatch
    ? runtime->dispatch(runtime, channel, payload)
    : 1;
}

static inline int32_t zapp_worker_runtime_join(uintptr_t identity) {
  ZappWorkerRuntime *runtime = (ZappWorkerRuntime *)identity;
  return runtime && runtime->join ? runtime->join(runtime) : 1;
}

static inline void zapp_worker_runtime_destroy(uintptr_t identity) {
  ZappWorkerRuntime *runtime = (ZappWorkerRuntime *)identity;
  if (runtime && runtime->destroy) runtime->destroy(runtime);
}

#ifdef __cplusplus
}
#endif

#endif
