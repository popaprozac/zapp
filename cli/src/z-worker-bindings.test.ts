import { describe, expect, test } from "bun:test";
import { renderZWorkerBindings } from "./z-worker-bindings";
import type { ZWorkerProtocolManifest } from "./z-program-metadata";

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
      fields: [{ name: "noteId", type: "u64" }],
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

describe("generated worker protocol bindings", () => {
  test("exposes typed commands and one exhaustive message stream", () => {
    const source = renderZWorkerBindings([protocol]);
    expect(source).toContain("export const noteIndexer");
    expect(source).not.toContain("export const noteIndexer = (() =>");
    expect(source).toContain('applicationWorkers.get("noteIndexer").send(');
    expect(source).toContain("input: IndexNotes");
    expect(source).toContain('applicationWorkers.get("noteIndexer").send(\n        "indexNotes"');
    expect(source).toContain("handler: (message: NoteIndexerMessage) => void");
    expect(source).toContain('worker.subscribe("progress"');
    expect(source).toContain("decodeIndexProgress(data)");
    expect(source).toContain("decodeU64");
    expect(source).toContain("export function defineNoteIndexerWorker(");
    expect(source).toContain("handlers.indexNotes(");
    expect(source).toContain("messages: NoteIndexerMessages");
    expect(source).toContain("return true;");
  });

  test("rejects typed worker IDs that cannot become generated symbols", () => {
    expect(() => renderZWorkerBindings([{ ...protocol, workerId: "note-indexer" }]))
      .toThrow(/typed worker ID/);
  });
});
