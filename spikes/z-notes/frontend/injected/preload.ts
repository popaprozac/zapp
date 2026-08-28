const scope = globalThis as unknown as Record<symbol, unknown>;
const bridge = scope[Symbol.for("zapp.bridge")];

scope[Symbol.for("zapp.inject.base.start")] =
  typeof bridge === "object" && bridge !== null ? "ready" : "missing-bridge";
