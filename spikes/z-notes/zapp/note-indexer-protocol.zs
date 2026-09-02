import { WorkerProtocol } from "zapp/worker";

export readonly struct IndexNotes {
  requestId: String;
}

export readonly struct IndexStarted {
  requestId: String;
}

export readonly struct IndexProgress {
  requestId: String;
  completed: usize;
  total: usize;
  noteId: u64;
  title: String;
}

export readonly struct IndexComplete {
  requestId: String;
  total: usize;
  active: usize;
  archived: usize;
  titleCharacters: usize;
}

export readonly struct IndexFailure {
  requestId: String;
  message: String;
}

export enum NoteIndexerCommand {
  indexNotes IndexNotes,
}

export enum NoteIndexerMessage {
  started IndexStarted,
  progress IndexProgress,
  complete IndexComplete,
  failed IndexFailure,
}

export type NoteIndexerProtocol =
  WorkerProtocol<NoteIndexerCommand, NoteIndexerMessage>;
