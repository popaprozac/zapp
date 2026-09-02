import { describe, expect, test } from "bun:test";
import {
  renderZApplicationWorkerCatalog,
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
