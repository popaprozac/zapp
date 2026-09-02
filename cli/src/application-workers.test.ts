import { describe, expect, test } from "bun:test";
import {
  renderZApplicationWorkerCatalog,
  renderZApplicationWorkerStartup,
  resolveApplicationWorkers,
} from "./application-workers";

describe("resolveApplicationWorkers", () => {
  test("freezes additive capability evidence without granting omitted profiles", () => {
    const workers = resolveApplicationWorkers({
      applicationWorkers: {
        searchIndexer: {
          script: "src/workers/search-indexer.ts",
          engine: "zjs",
          bytecode: true,
          capabilities: ["backgroundSearch", "diagnostics"],
          restart: {},
        },
        calculator: "src/workers/calculator.ts",
      },
    }, [
      {
        name: "backgroundSearch",
        permissions: ["fs:read"],
        serviceMethods: ["notes.list", "notes.updateIndex"],
      },
      {
        name: "diagnostics",
        permissions: [],
        serviceMethods: ["notes.list", "health.status"],
      },
    ]);

    expect(workers).toEqual([
      {
        id: "searchIndexer",
        script: "src/workers/search-indexer.ts",
        moduleUrl: "/_workers/_headless_searchIndexer.zbc",
        engine: "zjs",
        bytecode: true,
        restart: { maxRetries: 3, withinMs: 60_000 },
        capabilities: ["backgroundSearch", "diagnostics"],
        permissions: ["fs:read"],
        serviceMethods: ["notes.list", "notes.updateIndex", "health.status"],
      },
      {
        id: "calculator",
        script: "src/workers/calculator.ts",
        moduleUrl: "/_workers/_headless_calculator.mjs",
        engine: "zjs",
        bytecode: false,
        restart: false,
        capabilities: [],
        permissions: [],
        serviceMethods: [],
      },
    ]);
  });

  test("renders a typed immutable Z catalog with frozen authority", () => {
    const workers = resolveApplicationWorkers({
      applicationWorkers: {
        searchIndexer: {
          script: "src/workers/search-indexer.ts",
          engine: "bare-jsc",
          capabilities: ["backgroundSearch"],
          restart: { maxRetries: 2, withinMs: 5_000 },
        },
      },
    }, [{
      name: "backgroundSearch",
      permissions: ["fs:read"],
      serviceMethods: ["notes.list"],
    }]);

    const source = renderZApplicationWorkerCatalog(workers);
    expect(source).toContain("configuredApplicationWorkers");
    expect(source).toContain('id: "searchIndexer"');
    expect(source).toContain('moduleUrl: "/_workers/_headless_searchIndexer.mjs"');
    expect(source).toContain("engine: ApplicationWorkerEngine.bareJsc");
    expect(source).toContain("enabled: true");
    expect(source).toContain("maxRetries: 2");
    expect(source).toContain('worker0Permissions.push("fs:read")');
    expect(source).toContain('worker0ServiceMethods.push("notes.list")');
    expect(source).toContain("entries: workers.freeze()");
  });

  test("renders structured ZJS startup from an embedded bundled module", () => {
    const workers = resolveApplicationWorkers({
      applicationWorkers: {
        indexer: { script: "src/workers/indexer.ts", engine: "zjs" },
      },
    }, []);
    const source = renderZApplicationWorkerStartup(workers);
    expect(source).toContain(
      'embed.bytes("./worker/generated/application-worker-0.mjs")',
    );
    expect(source).toContain("startZjsApplicationWorker(");
    expect(source).toContain("catalog.entries[0].serviceMethods");
    expect(source).toContain("    services,");
    expect(source).toContain('name: "/_workers/_headless_indexer.mjs"');
    expect(source).toContain("controls: controls.freeze()");

    const smokeSource = renderZApplicationWorkerStartup(workers, true);
    expect(smokeSource).toContain(
      'match (control0.dispatch("ping", "configured-worker-smoke"))',
    );
    expect(smokeSource).toContain("accepted => {}\n    _ => control0.requestCancellation();");
    expect(smokeSource).toContain("control0.requestCancellation()");
  });

  test("fails closed for engines and bytecode outside the first native tier", () => {
    const nonZjs = resolveApplicationWorkers({
      applicationWorkers: {
        indexer: { script: "indexer.ts", engine: "bare-jsc" },
      },
    }, []);
    expect(() => renderZApplicationWorkerStartup(nonZjs)).toThrow(
      /first native runtime tier supports "zjs"/,
    );
    const bytecode = resolveApplicationWorkers({
      applicationWorkers: {
        indexer: { script: "indexer.ts", engine: "zjs", bytecode: true },
      },
    }, []);
    expect(() => renderZApplicationWorkerStartup(bytecode)).toThrow(
      /source-module startup must land before the ZJS bytecode loader/,
    );
  });

  test("fails closed when metadata resolution sees an unknown profile", () => {
    expect(() => resolveApplicationWorkers({
      applicationWorkers: {
        searchIndexer: {
          script: "src/workers/search-indexer.ts",
          capabilities: ["missing"],
        },
      },
    }, [])).toThrow(/unknown security capability profile "missing"/);
  });
});
