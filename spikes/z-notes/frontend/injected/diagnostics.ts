const scope = globalThis as unknown as Record<symbol, unknown>;
scope[Symbol.for("zapp.inject.diagnostics")] = "ready";
