# Zapp Documentation

These guides describe Zapp's current framework. Historical material is
explicitly identified below and is not a compatibility promise.

| File | What's in it |
|---|---|
| [`../spikes/z-notes/README.md`](../spikes/z-notes/README.md) | Runnable application: native services, windows, workers, permissions, and lifecycle |
| [`configuration.md`](configuration.md) | Typed configuration, immutable build policy, and current support boundaries |
| [`z-services.md`](z-services.md) | Native service registration, generated TypeScript clients, errors, and lifecycle |
| [`application-activation.md`](application-activation.md) | Reopen and custom URL events, startup buffering, and shutdown guarantees |
| [`api-reference.md`](api-reference.md#application-lifecycle) | Current frontend application lifecycle; later sections contain explicitly labeled legacy APIs |
| [`z-rewrite-charter.md`](z-rewrite-charter.md) | Architecture charter, product principles, milestones, and planned capabilities |
| [`z-native-core.md`](z-native-core.md) | Running, validating, and measuring the native framework |
| [`z-host-sdks.md`](z-host-sdks.md) | Future `libzapp` host SDK architecture, including Bun FFI and WebView IPC |

Existing document filenames are retained so links remain stable. Future designs
are labeled as such; platform support and measurements must name the implemented
and tested scope rather than inherit claims from prior implementations.

## Historical and contributor references

The earlier Nim/Zen-C implementations remain useful research. Their broader
platform/API coverage is not evidence that the same capability is implemented
in the current framework.

- [`engines.md`](engines.md), [`security.md`](security.md),
  [`patterns.md`](patterns.md), and [`architecture.md`](architecture.md) — earlier
  engine, security, API, and implementation reference material
- [`zen-c-services.md`](zen-c-services.md) — historical service authoring
- [`../llms.txt`](../llms.txt) — older API catalog; prefer the current guides above

Contributor entry points:

- [`../README.md`](../README.md) — project overview and historical reference
- [`../SKILLS.md`](../SKILLS.md) — contributor primer for hacking on Zapp itself
- [`../WINDOWS_PORTING.md`](../WINDOWS_PORTING.md) — Windows port status
- [`../benchmarks/README.md`](../benchmarks/README.md) — benchmark methodology
- [`../benchmarks/RESULTS.md`](../benchmarks/RESULTS.md) — latest measurements
