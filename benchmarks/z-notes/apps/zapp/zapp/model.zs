export struct Note {
  id: i64;
  title: String;
  body: String;
}

export struct CreateNoteInput {
  title: String;
  body: String;
}

export struct NotesPage {
  notes: Array<Note>;
  count: u64;
}

export struct BenchmarkReport {
  phase: String;
  payload: String;
}

export struct BenchmarkEcho {
  sequence: i32;
  label: String;
  active: boolean;
}

export struct NoteStorageError {
  code: i32;
  message: String;
}
