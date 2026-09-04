import sqlite from "sqlite3.h";
import { Note, NoteState } from "./notes-core.zs";
import { thread } from "std/thread";

export class NoteDatabase on thread.main {
  private database: sqlite.sqlite3;

  private constructor(database: sqlite.sqlite3) {
    this.database = move database;
  }

  static function open(in path: String): NoteDatabase throws i32 {
    let database;
    try sqlite.sqlite3_open(path, out database);
    if (database == null) throw -1;
    const opened = new NoteDatabase(move database);
    try opened.createSchema();
    return opened;
  }

  private function createSchema(): void throws i32 {
    let statement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, subtitle TEXT, state TEXT NOT NULL)",
      -1,
      out statement,
      null
    );
    if (statement == null) throw -1;
    const status = sqlite.sqlite3_step(statement);
    if (status != sqlite.SQLITE_DONE) throw status;
  }

  function loadNotes(): Array<Note> throws i32 {
    let notes = Array<Note>();
    let statement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "SELECT id, title, subtitle, state FROM notes ORDER BY id",
      -1,
      out statement,
      null
    );
    if (statement == null) throw -1;

    let status = sqlite.sqlite3_step(statement);
    while (status == sqlite.SQLITE_ROW) {
      const titleBytes = sqlite.sqlite3_column_text(statement, 1);
      if (titleBytes == null) throw -1;
      const stateBytes = sqlite.sqlite3_column_text(statement, 3);
      if (stateBytes == null) throw -1;
      const subtitleBytes = sqlite.sqlite3_column_text(statement, 2);
      const subtitle: Option<String> = subtitleBytes == null
        ? Option<String>.none
        : Option.some(String.from(subtitleBytes));
      const stateText = String.from(stateBytes);
      const state = stateText == "archived"
        ? NoteState.archived
        : NoteState.active;
      notes.push(Note({
        id: u64(sqlite.sqlite3_column_int64(statement, 0)),
        title: String.from(titleBytes),
        subtitle: move subtitle,
        state,
      }));
      status = sqlite.sqlite3_step(statement);
    }
    if (status != sqlite.SQLITE_DONE) throw status;
    return notes;
  }

  function insertNote(in note: Note): void throws i32 {
    let statement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "INSERT INTO notes (id, title, subtitle, state) VALUES (?, ?, ?, ?)",
      -1,
      out statement,
      null
    );
    if (statement == null) throw -1;
    try sqlite.sqlite3_bind_int64(statement, 1, i64(note.id));
    try sqlite.sqlite3_bind_text(statement, 2, note.title, -1);
    match (in note.subtitle) {
      some(subtitle) => try sqlite.sqlite3_bind_text(
        statement,
        3,
        subtitle,
        -1
      );
      none => try sqlite.sqlite3_bind_null(statement, 3);
    }
    const stateText = match (note.state) {
      active => "active";
      archived => "archived";
    };
    try sqlite.sqlite3_bind_text(statement, 4, stateText, -1);
    const status = sqlite.sqlite3_step(statement);
    if (status != sqlite.SQLITE_DONE) throw status;
  }

  function updateNote(in note: Note): void throws i32 {
    let statement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "UPDATE notes SET title = ?, subtitle = ?, state = ? WHERE id = ?",
      -1,
      out statement,
      null
    );
    if (statement == null) throw -1;
    try sqlite.sqlite3_bind_text(statement, 1, note.title, -1);
    match (in note.subtitle) {
      some(subtitle) => try sqlite.sqlite3_bind_text(
        statement,
        2,
        subtitle,
        -1
      );
      none => try sqlite.sqlite3_bind_null(statement, 2);
    }
    const stateText = match (note.state) {
      active => "active";
      archived => "archived";
    };
    try sqlite.sqlite3_bind_text(statement, 3, stateText, -1);
    try sqlite.sqlite3_bind_int64(statement, 4, i64(note.id));
    const status = sqlite.sqlite3_step(statement);
    if (status != sqlite.SQLITE_DONE) throw status;
  }

  function deleteNote(id: u64): void throws i32 {
    let statement;
    try sqlite.sqlite3_prepare_v2(
      this.database,
      "DELETE FROM notes WHERE id = ?",
      -1,
      out statement,
      null
    );
    if (statement == null) throw -1;
    try sqlite.sqlite3_bind_int64(statement, 1, i64(id));
    const status = sqlite.sqlite3_step(statement);
    if (status != sqlite.SQLITE_DONE) throw status;
  }
}

export class NotesStorage on thread.main {
  private database: Option<NoteDatabase>;

  constructor() {
    this.database = Option<NoteDatabase>.none;
  }

  function install(inout this, database: NoteDatabase): void {
    this.database = Option.some(database);
  }

  function insert(in note: Note): void throws i32 {
    match (in this.database) {
      some(database) => try database.insertNote(in note);
      none => throw -1;
    }
  }

  function update(in note: Note): void throws i32 {
    match (in this.database) {
      some(database) => try database.updateNote(in note);
      none => throw -1;
    }
  }

  function delete(id: u64): void throws i32 {
    match (in this.database) {
      some(database) => try database.deleteNote(id);
      none => throw -1;
    }
  }

  function close(inout this): void {
    this.database = Option.none;
  }
}

export function createNotesStorage(): NotesStorage on thread.main {
  return new NotesStorage();
}
