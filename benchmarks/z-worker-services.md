# Z worker service benchmark

This benchmark isolates Zapp's defining worker fast path while using the same
generated service facade that application code imports. It runs inside the
configured ZJS application worker in Z Notes and reports two boundaries:

| Boundary | Included work |
|---|---|
| Direct host | ZJS host call, JSON argument/result projection, immutable worker capability lookup, frozen Z service lookup, Z handler, and return to ZJS |
| Generated Promise API | The direct host boundary plus `zapp:services`, generated result decoding, Promise settlement, and one sequential microtask continuation per call |

Run it with:

```sh
bun run bench:z-notes:worker
```

The harness performs 200 unreported warmups, then five samples. Each direct
sample makes 10,000 calls; each generated-API sample makes 1,000 sequential
settled calls. The benchmark validates every returned value, runs through the
real configured worker allowlist, and fails unless the worker finishes all
samples and shuts down cleanly.

## September 2, 2026 checkpoint

Environment: Apple M4 Pro, arm64, macOS 26.4; optimized Z native build; current
in-tree ZJS compatibility archive.

| Boundary | Median | Observed five-sample range |
|---|---:|---:|
| Direct host | 351 ns/call | 317-511 ns/call |
| Generated Promise API | 2.275 us/call | 2.040-3.658 us/call |
| Existing no-op WebView round trip | 79 us/call | Separate established WebView checkpoint |

The user-facing generated worker API is approximately 35 times faster than the
existing WebView baseline for this small-result route. The raw direct host is
approximately 225 times faster. These ratios are architectural evidence, not a
cross-framework score: the worker measurement uses `health.status()` with no
input, while the historical WebView figure is the framework no-op probe.

The strict native host previously measured the frozen Z `notes.count` router at
257-279 ns/call. The ZJS direct result is therefore in the same sub-microsecond
tier even though it crosses the engine boundary and parses the JSON result.

## Hot-path inspection

Three avoidable costs were removed before recording the result:

- no-argument calls now borrow static `"null"` bytes instead of allocating and
  immediately freeing a temporary C buffer;
- the worker's immutable identity is captured once by its service callback
  instead of being copied from C bytes on every authorized call; and
- the owned method string moves into `Services.invoke` instead of being
  deep-copied before dispatch.

The remaining material costs are explicit: conversion of the method and
arguments into owned Z strings, splitting the full method into service and
method names for lookup, JSON result encoding, one response-lifetime copy, JSON
result parsing, and Promise/generated-codec work in the public path. A future
full-method route table plus borrowed-key lookup could remove several string
allocations without changing the public service API. Direct typed engine-value
projection could later remove the intermediate JSON document for supported
wire types; JSON remains the correctness-first fallback.

The current ZJS worker bundle is intentionally unminified because the legacy
compatibility artifact misexecutes one Rolldown compact-control-flow rewrite.
That affects bundled worker bytes, not these per-call timings. The ZJS rewrite
must use this benchmark and compatibility smoke before minification is restored.
