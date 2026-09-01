import { describe, expect, test } from "bun:test";
import { resolveApplicationWorkers } from "./application-workers";

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
        bytecode: false,
        restart: false,
        capabilities: [],
        permissions: [],
        serviceMethods: [],
      },
    ]);
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
