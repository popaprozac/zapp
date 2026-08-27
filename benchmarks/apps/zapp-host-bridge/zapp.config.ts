// Zapp host-bridge benchmark — measures per-call cost of the three
// host-bridge surfaces user code actually pays for, side by side
// across surviving engines. The headless workers below auto-run
// their bench suite at startup and log results to stderr; `run.sh`
// launches the app, captures the log, and aggregates.
//
// Engine selection is the single source of truth here: the CLI
// synthesises the matching `ZAPP_WORKER_ENGINE_*` defines from the
// `engine:` field on each worker. To compare an additional engine,
// add a worker entry below — no build.zc edits needed.
import { defineConfig } from "../../../cli/src/config.ts";

export default defineConfig({
  application: {
    name: "bench-host-bridge",
    identifier: "com.zapp.bench.host-bridge",
    version: "0.0.0",
  },
  // Auto-merged via cli/src/entitlements.ts when a JSC-class engine
  // is enabled — explicit here so the bench numbers are honest about
  // running with JIT (without `allow-jit`, bare-jsc falls back to the
  // interpreter and the comparison becomes meaningless).
  targets: {
    macOS: {
      entitlements: {
        "com.apple.security.cs.allow-jit": true,
      },
    },
  },
  workers: {
    headless: {
      // Two-engine matrix today. Multi-bare-engine builds fail with
      // duplicate-library / bad-path link errors — appears the CLI's
      // build-config.ts emits stomping link directives when more than
      // one bare-* engine is enabled. Workaround: swap engines between
      // runs and merge the RESULTS.md numbers by hand.
      //
      // Engines deliberately excluded today:
      //   bare-hermes — #168 fetch hang; numbers wouldn't be honest.
      //   bare-mqjs   — vendor/bare's libmqjs cmake step needs the
      //                 `mqjs-build` external tool not shipped with the
      //                 toolchain. Tracked.
      "bench-zjs":      { script: "src/bench-worker.ts", engine: "zjs" },
      "bench-bare-jsc": { script: "src/bench-worker.ts", engine: "bare-jsc" },
    },
  },
});
