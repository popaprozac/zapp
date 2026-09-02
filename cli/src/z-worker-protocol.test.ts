import { describe, expect, test } from "bun:test";
import {
  deriveZWorkerProtocolManifest,
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
});
