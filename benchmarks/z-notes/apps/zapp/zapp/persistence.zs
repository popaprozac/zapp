import sqlite from "sqlite3.h";
import { Note } from "./model.zs";

struct NoteDatabase {
  database: sqlite.sqlite3;

  function loadNotes(): Array<Note> throws i32 {
    let notes = Array<Note>();
    const rowStatus = sqlite.SQLITE_ROW;
    const doneStatus = sqlite.SQLITE_DONE;

    let schemaStatement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL)",
      -1,
      out schemaStatement,
      null
    );
    if (schemaStatement == null) throw -1;
    const schemaStatus = sqlite.sqlite3_step(schemaStatement);
    if (schemaStatus != doneStatus) throw schemaStatus;

    let seedStatement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "INSERT OR IGNORE INTO notes (id, title, body) VALUES (1, 'Welcome to Z Notes', 'A native notes application implemented across desktop frameworks.'), (2, 'One workload', 'The frontend, storage behavior, and workflow stay equivalent.')",
      -1,
      out seedStatement,
      null
    );
    if (seedStatement == null) throw -1;
    const seedStatus = sqlite.sqlite3_step(seedStatement);
    if (seedStatus != doneStatus) throw seedStatus;

    let queryStatement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "SELECT id, title, body FROM notes ORDER BY id",
      -1,
      out queryStatement,
      null
    );
    if (queryStatement == null) throw -1;

    let stepStatus = sqlite.sqlite3_step(queryStatement);
    while (stepStatus == rowStatus) {
      const titleBytes = sqlite.sqlite3_column_text(queryStatement, 1);
      if (titleBytes == null) throw -1;
      const bodyBytes = sqlite.sqlite3_column_text(queryStatement, 2);
      if (bodyBytes == null) throw -1;
      const title: String = String.from(titleBytes);
      const body: String = String.from(bodyBytes);
      notes.push(Note({
        id: sqlite.sqlite3_column_int64(queryStatement, 0),
        title,
        body,
      }));
      stepStatus = sqlite.sqlite3_step(queryStatement);
    }
    if (stepStatus != doneStatus) throw stepStatus;
    return notes;
  }

  function insertNote(in note: Note): void throws i32 {
    const doneStatus = sqlite.SQLITE_DONE;
    let statement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "INSERT INTO notes (id, title, body) VALUES (?, ?, ?)",
      -1,
      out statement,
      null
    );
    if (statement == null) throw -1;
    try sqlite.sqlite3_bind_int64(statement, 1, note.id);
    // The borrowed strings remain live through sqlite3_step and statement
    // finalization, so SQLite's null destructor (SQLITE_STATIC) is valid here.
    // This also keeps the benchmark on the native fixed-point importer while
    // expression-like C macro import is still a documented future layer.
    try sqlite.sqlite3_bind_text(statement, 2, note.title, -1, null);
    try sqlite.sqlite3_bind_text(statement, 3, note.body, -1, null);
    const status = sqlite.sqlite3_step(statement);
    if (status != doneStatus) throw status;
  }
}

function openDatabase(in path: String): NoteDatabase throws i32 {
  let database;
  try sqlite.sqlite3_open(path, out database);
  if (database == null) throw -1;
  return NoteDatabase({ database: move database });
}

export function loadNotesFromPath(in path: String): Array<Note> throws i32 {
  const database = try openDatabase(in path);
  return try database.loadNotes();
}

export function saveNoteToPath(in path: String, in note: Note): void throws i32 {
  const database = try openDatabase(in path);
  try database.insertNote(in note);
}
