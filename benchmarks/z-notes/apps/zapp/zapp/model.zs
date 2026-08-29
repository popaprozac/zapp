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
  notesJson: String;
  count: u64;
}

export struct BenchmarkReport {
  phase: String;
  payload: String;
}

export struct NoteStorageError {
  code: i32;
  message: String;
}
