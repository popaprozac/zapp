#pragma once

#include <stdbool.h>
#include <stdint.h>

void zapp_deliver_response_from_z(
  const char *payload,
  uint64_t request_id,
  bool ok,
  int32_t window_id
);
