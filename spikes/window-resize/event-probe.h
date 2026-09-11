// Test-only observation. Counts explicit allocation requests in emitted Z code.
// Clang may eliminate the backing storage; this is not a libc allocation trace,
// nor does it count Foundation/WebKit internals, ARC traffic, or peak live memory.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <assert.h>
#include <mach/mach_time.h>

enum { PROBE_LIMIT = 4096, PROBE_STAGES = 5 };
static double probe_samples[PROBE_STAGES][PROBE_LIMIT];
static int probe_counts[PROBE_STAGES];
static int probe_stage = -1;
static double probe_started;
static uint64_t probe_allocations[PROBE_STAGES];
static double probe_sent_at[PROBE_LIMIT];
static uint32_t probe_widths[PROBE_LIMIT], probe_heights[PROBE_LIMIT];
static int probe_sent_count, probe_completed_count, probe_peak_pending;
static uint64_t probe_script_bytes;
static double probe_now(void) {
  static mach_timebase_info_data_t timebase;
  if (timebase.denom == 0) mach_timebase_info(&timebase);
  return (double)mach_absolute_time() * (double)timebase.numer / (double)timebase.denom / 1e9;
}
static inline void probe_begin(int32_t stage) {
  assert(stage >= 0 && stage < PROBE_STAGES && probe_stage == -1);
  probe_stage = stage;
  probe_started = probe_now();
}
static inline void probe_end(void) {
  const int stage = probe_stage;
  assert(stage >= 0 && probe_counts[stage] < PROBE_LIMIT);
  probe_samples[stage][probe_counts[stage]++] = (probe_now() - probe_started) * 1e6;
  probe_stage = -1;
}
static __attribute__((noinline, unused)) void *probe_malloc(size_t size) {
  if (probe_stage >= 0) ++probe_allocations[probe_stage];
  return malloc(size);
}
static __attribute__((noinline, unused)) void *probe_calloc(size_t count, size_t size) {
  if (probe_stage >= 0) ++probe_allocations[probe_stage];
  return calloc(count, size);
}
static __attribute__((noinline, unused)) void *probe_realloc(void *pointer, size_t size) {
  if (probe_stage >= 0) ++probe_allocations[probe_stage];
  return realloc(pointer, size);
}
static inline int32_t probe_sent(size_t bytes, uint32_t width, uint32_t height) {
  assert(probe_sent_count < PROBE_LIMIT);
  probe_script_bytes += bytes;
  probe_sent_at[probe_sent_count] = probe_now();
  probe_widths[probe_sent_count] = width;
  probe_heights[probe_sent_count] = height;
  ++probe_sent_count;
  int pending = probe_sent_count - probe_completed_count;
  if (pending > probe_peak_pending) probe_peak_pending = pending;
  return probe_sent_count - 1;
}
static inline void probe_completed(int32_t index, _Bool success) {
  assert(success && index == probe_completed_count && index < probe_sent_count);
  probe_samples[4][probe_counts[4]++] = (probe_now() - probe_sent_at[index]) * 1e6;
  ++probe_completed_count;
}
static inline int32_t probe_pending(void) { return probe_sent_count - probe_completed_count; }
static inline int32_t probe_sent_total(void) { return probe_sent_count; }
static int probe_compare(const void *a, const void *b) {
  double left = *(const double *)a, right = *(const double *)b;
  return (left > right) - (left < right);
}
static inline void probe_report(void) {
  const char *names[] = {"publishEmpty", "publishTwoListeners", "serialize", "enqueue", "webKitCompletion"};
  for (int stage = 0; stage < PROBE_STAGES; ++stage) {
    int count = probe_counts[stage];
    assert(count > 0);
    qsort(probe_samples[stage], (size_t)count, sizeof(double), probe_compare);
    printf("METRIC {\"stage\":\"%s\",\"count\":%d,\"medianUs\":%.3f,\"p95Us\":%.3f,\"allocationCalls\":%llu}\n",
      names[stage], count, probe_samples[stage][count / 2], probe_samples[stage][(count - 1) * 95 / 100],
      (unsigned long long)probe_allocations[stage]);
  }
  printf("DELIVERY {\"sent\":%d,\"completed\":%d,\"peakPending\":%d,\"scriptBytes\":%llu}\n",
    probe_sent_count, probe_completed_count, probe_peak_pending, (unsigned long long)probe_script_bytes);
  printf("EXPECTED [");
  for (int i = 0; i < probe_sent_count; ++i) {
    printf("%s[\"probe-window\",%u,%u]", i == 0 ? "" : ",", probe_widths[i], probe_heights[i]);
  }
  printf("]\n");
}
