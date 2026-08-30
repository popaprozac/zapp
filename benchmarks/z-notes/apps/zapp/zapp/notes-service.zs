import console from "std/console";
import fs from "std/fs";
import { thread } from "std/thread";
import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
} from "zapp/service";
import {
  BenchmarkEcho,
  CreateNoteInput,
  BenchmarkReport,
  Note,
  NoteStorageError,
  NotesPage,
} from "./model.zs";

const benchmarkControlPath = "/tmp/z-notes-benchmark-zapp.control";
const benchmarkReadyPath = "/tmp/z-notes-benchmark-zapp.ready";
const benchmarkResultPath = "/tmp/z-notes-benchmark-zapp.result.json";

function writeBenchmarkReport(
  in path: String,
  in phase: String,
  in payload: String
): boolean {
  const written = attempt fs.writeText(path, payload);
  match (written) {
    success => return true;
    failure(message) => {
      console.log(`could not report benchmark ${phase}: ${message}`);
      return false;
    }
  }
}
import {
  loadNotesFromPath,
  saveNoteToPath,
} from "./persistence.zs";

function storageError(code: i32): NoteStorageError {
  return NoteStorageError({
    code,
    message: `SQLite operation failed with status ${code}`,
  });
}

export readonly class NotesService implements ServiceLifecycle {
  readonly databasePath: String;

  function list(): NotesPage throws NoteStorageError {
    const databasePath = copy this.databasePath;
    const loaded = attempt loadNotesFromPath(in databasePath);
    const notes = match (loaded) {
      success(notes) => notes;
      failure(code) => throw storageError(code);
    };
    const count = u64(notes.length);
    return NotesPage({
      notes: move notes,
      count,
    });
  }

  function create(input: CreateNoteInput): Note throws NoteStorageError {
    const { title, body } = move input;
    if (title.byteLength == 0) {
      throw NoteStorageError({ code: -1, message: "a note title is required" });
    }
    const databasePath = copy this.databasePath;
    const loaded = attempt loadNotesFromPath(in databasePath);
    const notes = match (loaded) {
      success(notes) => notes;
      failure(code) => throw storageError(code);
    };
    let nextId: i64 = 1;
    for (const existing of notes) {
      if (existing.id >= nextId) nextId = existing.id + 1;
    }
    const note = Note({
      id: nextId,
      title: move title,
      body: move body,
    });
    const saved = attempt saveNoteToPath(in databasePath, in note);
    match (saved) {
      success => {}
      failure(code) => throw storageError(code);
    }
    return note;
  }

  function benchmarkMode(): boolean {
    return fs.exists(benchmarkControlPath);
  }

  function benchmarkNoop(): boolean {
    return true;
  }

  function benchmarkEcho(input: BenchmarkEcho): BenchmarkEcho {
    return move input;
  }

  function reportBenchmark(report: BenchmarkReport): boolean {
    const { phase, payload } = move report;
    if (phase == "ready") {
      return writeBenchmarkReport(benchmarkReadyPath, phase, payload);
    }
    return writeBenchmarkReport(benchmarkResultPath, phase, payload);
  }

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    console.log(`${context.metadata.name}: benchmark notes service started`);
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    console.log(`${context.metadata.name}: benchmark notes service stopped`);
  }
}

export function createNotesService(): NotesService {
  return new NotesService({
    databasePath: "/tmp/z-notes-benchmark-zapp.sqlite3",
  });
}
