import { describe, expect, test } from "bun:test";
import type { ZWorkerProtocolManifest } from "./z-program-metadata";
import {
  renderZWorkerProtocolAdapters,
  zWorkerProtocolBuildContribution,
} from "./z-worker-native";

const protocol: ZWorkerProtocolManifest = {
  schemaVersion: 1,
  workerId: "noteIndexer",
  module: "/app/note-indexer-protocol.zs",
  protocolType: "NoteIndexerProtocol",
  commandType: "NoteIndexerCommand",
  messageType: "NoteIndexerMessage",
  types: [
    {
      name: "IndexNotes",
      module: "/app/note-indexer-protocol.zs",
      fields: [{ name: "requestId", type: "String" }],
    },
    {
      name: "IndexProgress",
      module: "/app/note-indexer-protocol.zs",
      fields: [{ name: "completed", type: "usize" }],
    },
  ],
  enums: [
    {
      name: "NoteIndexerCommand",
      module: "/app/note-indexer-protocol.zs",
      variants: [{ name: "indexNotes", payload: "IndexNotes" }],
    },
    {
      name: "NoteIndexerMessage",
      module: "/app/note-indexer-protocol.zs",
      variants: [{ name: "progress", payload: "IndexProgress" }],
    },
  ],
};

describe("native typed worker protocol adapters", () => {
  test("renders checked command and Result-valued message codecs in Z", () => {
    const source = renderZWorkerProtocolAdapters([protocol], {
      outputPath: "/build/generated/worker-protocols.zs",
      workerModule: "/build/framework/worker-manager.zs",
    });
    expect(source).toContain("function __zappEncodeNoteIndexerCommand(");
    expect(source).toContain("const encoded = __zappEncodeIndexNotes(move value);");
    expect(source).toContain("payload: json.stringify(in encoded)");
    expect(source).toContain("function __zappDecodeNoteIndexerMessage(");
    expect(source).toContain(
      "): Result<NoteIndexerMessage, ApplicationWorkerProtocolError> =>",
    );
    expect(source).toContain("attempt __zappDecodeNoteIndexerMessage(in message)");
    expect(source).toContain("encode: move encode");
    expect(source).toContain("accepts: move accepts");
    expect(source).toContain("decode: move decode");
  });

  test("contributes one checked call adapter for each typed lookup", () => {
    expect(zWorkerProtocolBuildContribution(
      [protocol],
      [{ workerId: "noteIndexer", module: "/app/main.zs", offset: 42 }],
      "/build/generated/worker-protocols.zs",
    )).toEqual({
      modules: [{
        specifier: "zapp/generated/worker-protocols",
        source: "/build/generated/worker-protocols.zs",
        packageName: "zapp",
      }],
      callAdapters: [{
        source: "/app/main.zs",
        offset: 42,
        target: "WorkerManager.get",
        replacement: "WorkerManager.getGenerated",
        argument: 0,
        adapterModule: "zapp/generated/worker-protocols",
        adapterExport: "__zappAdaptNoteIndexerWorkerProtocol",
      }],
    });
  });
});
