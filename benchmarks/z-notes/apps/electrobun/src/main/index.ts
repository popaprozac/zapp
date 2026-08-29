import Database from "bun:sqlite";
import { existsSync, writeFileSync } from "node:fs";
import { BrowserView, BrowserWindow } from "electrobun/main";
import type {
  CreateNoteInput,
  Note,
  NotesRPC,
} from "../shared/schema";

const databasePath = "/tmp/z-notes-benchmark-electrobun.sqlite3";
const benchmarkControl = "/tmp/z-notes-benchmark-electrobun.control";
const benchmarkReady = "/tmp/z-notes-benchmark-electrobun.ready";
const benchmarkResult = "/tmp/z-notes-benchmark-electrobun.result.json";

function openDatabase(): Database {
  const database = new Database(databasePath, { create: true });
  database.exec(`
CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL
);
INSERT OR IGNORE INTO notes (id, title, body) VALUES
  (1, 'Welcome to Z Notes', 'A native notes application implemented across desktop frameworks.'),
  (2, 'One workload', 'The frontend, storage behavior, and workflow stay equivalent.');
`);
  return database;
}

function listNotes(): Note[] {
  const database = openDatabase();
  try {
    const rows = database
      .query("SELECT id, title, body FROM notes ORDER BY id")
      .all() as Array<{ id: number; title: string; body: string }>;
    return rows.map((note) => ({
      id: String(note.id),
      title: note.title,
      body: note.body,
    }));
  } finally {
    database.close();
  }
}

function createNote(input: CreateNoteInput): Note {
  if (input.title.length === 0) throw new Error("a note title is required");
  const database = openDatabase();
  try {
    const next = database
      .query("SELECT COALESCE(MAX(id), 0) + 1 AS id FROM notes")
      .get() as { id: number };
    database
      .query("INSERT INTO notes (id, title, body) VALUES (?, ?, ?)")
      .run(next.id, input.title, input.body);
    return {
      id: String(next.id),
      title: input.title,
      body: input.body,
    };
  } finally {
    database.close();
  }
}

const notesRPC = BrowserView.defineRPC<NotesRPC>({
  maxRequestTime: 5_000,
  handlers: {
    requests: {
      list: listNotes,
      create: createNote,
      benchmarkMode: () => existsSync(benchmarkControl),
      reportBenchmark: ({ phase, payload }) => {
        writeFileSync(phase === "ready" ? benchmarkReady : benchmarkResult, payload);
        return true;
      },
    },
    messages: {},
  },
});

new BrowserWindow({
  title: "Z Notes Benchmark",
  url: "views://mainview/index.html",
  rpc: notesRPC,
  frame: {
    width: 860,
    height: 600,
    x: 200,
    y: 200,
  },
});
