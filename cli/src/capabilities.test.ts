import { describe, expect, it } from "bun:test";
import { resolveCapabilityProfiles } from "./capabilities";
import type { ZServiceManifest } from "./z-service-bindings";

const manifest: ZServiceManifest = {
  schemaVersion: 5,
  types: [],
  enums: [],
  errors: [],
  services: [{
    name: "notes",
    type: "NotesService",
    kind: "class",
    module: "/app/notes.zs",
    lifecycle: false,
    registration: {
      module: "/app/main.zs",
      offset: 0,
      line: 1,
      column: 1,
      method: "ApplicationServices.register",
    },
    methods: [
      {
        id: 1,
        name: "create",
        returns: "String",
        asynchronous: false,
        executorAffinity: null,
        receiverMode: "in",
      },
      {
        id: 2,
        name: "count",
        returns: "u32",
        asynchronous: false,
        executorAffinity: null,
        receiverMode: "in",
      },
    ],
  }],
};

describe("resolveCapabilityProfiles", () => {
  it("synthesizes a backwards-compatible default from registrations and global policy", () => {
    expect(resolveCapabilityProfiles({
      permissions: ["window:create"],
    }, manifest)).toEqual([{
      name: "default",
      permissions: ["window:create"],
      serviceMethods: ["notes.create", "notes.count"],
      workerIds: [],
    }]);
  });

  it("expands service grants and preserves narrow exact methods", () => {
    const resolved = resolveCapabilityProfiles({
      permissions: ["window:create"],
      capabilityProfiles: {
        default: {
          permissions: ["window:create"],
          services: ["notes"],
          workers: ["indexer"],
        },
        diagnostics: { services: ["notes.count"] },
      },
      applicationWorkers: { indexer: "./indexer.ts" },
    }, manifest);
    expect(resolved).toEqual([
      {
        name: "default",
        permissions: ["window:create"],
        serviceMethods: ["notes.create", "notes.count"],
        workerIds: ["indexer"],
      },
      {
        name: "diagnostics",
        permissions: [],
        serviceMethods: ["notes.count"],
        workerIds: [],
      },
    ]);
  });

  it("fails the build for unknown service and method selectors", () => {
    expect(() => resolveCapabilityProfiles({
      capabilityProfiles: { default: { services: ["notes.missing"] } },
    }, manifest)).toThrow(/unknown selector "notes.missing"/);
    expect(() => resolveCapabilityProfiles({
      capabilityProfiles: { default: { services: ["missing"] } },
    }, manifest)).toThrow(/unknown selector "missing"/);
  });
});
