import { describe, expect, test } from "bun:test";
import {
  deriveZWorkerProtocolManifest,
  deriveZWorkerProtocolUses,
  type ZProgramMetadata,
} from "./z-program-metadata";

function protocolMetadata(alias: string): ZProgramMetadata {
  const typeSignature = (kind: "struct" | "enum", detail: unknown) => ({
    implementedTraits: [],
    fields: kind === "struct" ? detail : [],
    methods: [],
    variants: kind === "enum" ? detail : [],
  });
  return {
    schemaVersion: 1,
    entry: 0,
    modules: [{
      path: "/app/protocol.zs",
      calls: [],
      symbols: [
        {
          name: "IndexRequest",
          kind: "struct",
          exported: true,
          importedName: "IndexRequest",
          typeSignature: typeSignature("struct", [{
            name: "requestId",
            typeName: "String",
            visibility: "public",
            optionalField: false,
          }]),
        },
        {
          name: "IndexProgress",
          kind: "struct",
          exported: true,
          importedName: "IndexProgress",
          typeSignature: typeSignature("struct", [{
            name: "completed",
            typeName: "usize",
            visibility: "public",
            optionalField: false,
          }]),
        },
        {
          name: "IndexCommand",
          kind: "enum",
          exported: true,
          importedName: "IndexCommand",
          typeSignature: typeSignature("enum", [{
            name: "index",
            payloadType: "IndexRequest",
          }]),
        },
        {
          name: "IndexMessage",
          kind: "enum",
          exported: true,
          importedName: "IndexMessage",
          typeSignature: typeSignature("enum", [{
            name: "progress",
            payloadType: "IndexProgress",
          }]),
        },
        {
          name: "IndexProtocol",
          kind: "type",
          exported: true,
          importedName: alias,
          typeSignature: null,
        },
      ],
    }],
  } as ZProgramMetadata;
}

describe("checked Z worker protocols", () => {
  test("derives command, message, and payload wire types from the marker alias", () => {
    const manifest = deriveZWorkerProtocolManifest(
      protocolMetadata("WorkerProtocol<IndexCommand, IndexMessage>"),
      "indexer",
      "/app/protocol.zs",
      "IndexProtocol",
    );
    expect(manifest.commandType).toBe("IndexCommand");
    expect(manifest.messageType).toBe("IndexMessage");
    expect(manifest.enums.map((value) => value.name)).toEqual([
      "IndexCommand",
      "IndexMessage",
    ]);
    expect(manifest.types.map((value) => value.name)).toEqual([
      "IndexRequest",
      "IndexProgress",
    ]);
  });

  test("rejects aliases that do not identify the protocol marker", () => {
    expect(() => deriveZWorkerProtocolManifest(
      protocolMetadata("IndexCommand"),
      "indexer",
      "/app/protocol.zs",
      "IndexProtocol",
    )).toThrow(/must alias WorkerProtocol<Command, Message>/);
  });

  test("resolves typed manager lookups to one configured protocol", () => {
    const metadata = protocolMetadata(
      "WorkerProtocol<IndexCommand, IndexMessage>",
    );
    metadata.modules[0].calls.push({
      offset: 420,
      line: 12,
      column: 18,
      target: {
        module: "/zapp/worker.zs",
        symbol: "WorkerManager",
        kind: "method",
        name: "WorkerManager.get",
      },
      arguments: [{
        kind: "other",
        type: "WorkerProtocol<IndexCommand, IndexMessage>",
      }],
    });
    const protocol = deriveZWorkerProtocolManifest(
      metadata,
      "indexer",
      "/app/protocol.zs",
      "IndexProtocol",
    );
    expect(deriveZWorkerProtocolUses(metadata, [protocol])).toEqual([{
      workerId: "indexer",
      module: "/app/protocol.zs",
      offset: 420,
    }]);
  });

  test("fails closed when a typed lookup has no unique configured worker", () => {
    const metadata = protocolMetadata(
      "WorkerProtocol<IndexCommand, IndexMessage>",
    );
    metadata.modules[0].calls.push({
      offset: 420,
      line: 12,
      column: 18,
      target: {
        module: "/zapp/worker.zs",
        symbol: "WorkerManager",
        kind: "method",
        name: "WorkerManager.get",
      },
      arguments: [{
        kind: "other",
        type: "WorkerProtocol<IndexCommand, IndexMessage>",
      }],
    });
    const protocol = deriveZWorkerProtocolManifest(
      metadata,
      "indexer",
      "/app/protocol.zs",
      "IndexProtocol",
    );
    expect(() => deriveZWorkerProtocolUses(metadata, []))
      .toThrow(/no configured application worker/);
    expect(() => deriveZWorkerProtocolUses(metadata, [
      protocol,
      { ...protocol, workerId: "secondIndexer" },
    ])).toThrow(/requires one configured worker per protocol/);
  });
});
