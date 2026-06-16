// `import type` is erased at compile time — no runtime resolution
// (the monorepo aliases only apply to the app bundle, not config loading).
import type { ZappConfig } from "@zappdev/cli/config";

const config: ZappConfig = {
  name: "kitchen-sink",
  identifier: "com.zapp.kitchensink",
  version: "0.1.0",
  // Add headless TypeScript workers that start when the app boots.
  // New projects default to `engine: "zjs"` — first-party,
  // cross-platform, small, iOS-friendly. On macOS you can opt into
  // `engine: "bare-jsc"` for JIT (zero bundle cost via system JSC)
  // at the price of opting into bare-* packages for web APIs.
  //
  //   headless: {
  //     db: { script: "src/workers/db.ts", engine: "zjs" },
  //   },
};

export default config;
