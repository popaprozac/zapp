import { Map } from "std/collections";
import json from "std/json";
import {
  CreateNoteInput,
  Note,
  NoteState,
} from "./notes-core.zs";

struct NoteFileEntry {
  title: String;
  subtitle: String = "";
  state: String = "active";
}

export struct NotesTransferDecodeError {
  message: String;
}

function decodeError(message: String): NotesTransferDecodeError {
  return NotesTransferDecodeError({ message: move message });
}

function noteStateName(state: NoteState): String {
  return match (state) {
    active => "active";
    archived => "archived";
  };
}

function encodeNote(in note: Note): json.JsonValue {
  let fields = Map<String, json.JsonValue>();
  fields.set("title", json.JsonValue.string(copy note.title));
  match (in note.subtitle) {
    some(subtitle) => fields.set(
      "subtitle",
      json.JsonValue.string(copy subtitle)
    );
    none => fields.set("subtitle", json.JsonValue.string(""));
  }
  fields.set(
    "state",
    json.JsonValue.string(noteStateName(note.state))
  );
  return json.JsonValue.object(move fields);
}

export function encodeNotesDocument(in notes: Array<Note>): String {
  let encodedNotes = Array<json.JsonValue>();
  for (const note of notes) {
    encodedNotes.push(encodeNote(in note));
  }
  let document = Map<String, json.JsonValue>();
  document.set(
    "version",
    json.JsonValue.number(json.JsonNumber.fromU64(1))
  );
  document.set("notes", json.JsonValue.array(move encodedNotes));
  const value = json.JsonValue.object(move document);
  return json.stringify(in value);
}

function decodeEntry(
  in value: json.JsonValue
): CreateNoteInput throws NotesTransferDecodeError {
  const source = json.stringify(in value);
  const decoded = attempt json.decode<NoteFileEntry>(in source);
  const entry = match (decoded) {
    success(value) => value;
    failure(error) => throw decodeError(
      `invalid note at line ${error.line}, column ${error.column}: ${error.message}`
    );
  };
  if (entry.title.byteLength == 0) {
    throw decodeError("imported note titles cannot be empty");
  }
  let state = NoteState.active;
  if (entry.state == "archived") {
    state = NoteState.archived;
  } else if (entry.state != "active") {
    throw decodeError(`unknown note state ${entry.state}`);
  }
  const subtitle: Option<String> = entry.subtitle.byteLength == 0
    ? Option<String>.none
    : Option.some(copy entry.subtitle);
  return CreateNoteInput({
    title: copy entry.title,
    subtitle: move subtitle,
    state,
  });
}

export function decodeNotesDocument(
  in source: String
): Array<CreateNoteInput> throws NotesTransferDecodeError {
  const parsed = attempt json.parse(in source);
  match (parsed) {
    success(value) => match (value) {
      object(fields) => return try decodeDocument(in fields);
      _ => throw decodeError("notes document must be a JSON object");
    }
    failure(error) => throw decodeError(
      `invalid JSON at line ${error.line}, column ${error.column}: ${error.message}`
    );
  }
}

function decodeDocument(
  in document: Map<String, json.JsonValue>
): Array<CreateNoteInput> throws NotesTransferDecodeError {
  const versionValue = document.get("version");
  let version: u64 = 0;
  match (in versionValue) {
    some(value) => match (in value) {
      number(number) => {
        const converted = attempt number.toU64();
        match (converted) {
          success(value) => version = value;
          failure(error) => throw decodeError(copy error.message);
        }
      }
      _ => throw decodeError("notes document version must be an integer");
    }
    none => throw decodeError("notes document is missing version");
  }
  if (version != 1) {
    throw decodeError(`unsupported notes document version ${version}`);
  }

  const notesValue = document.get("notes");
  match (in notesValue) {
    some(value) => match (in value) {
      array(entries) => return try decodeEntries(in entries);
      _ => throw decodeError("notes document notes must be an array");
    }
    none => throw decodeError("notes document is missing notes");
  }
}

function decodeEntries(
  in entries: Array<json.JsonValue>
): Array<CreateNoteInput> throws NotesTransferDecodeError {
  let notes = Array<CreateNoteInput>();
  for (const entry of entries) {
    notes.push(try decodeEntry(in entry));
  }
  return notes;
}
