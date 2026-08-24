import {
  JsonValue,
  parse,
  stringify,
} from "std/json";
import { Map } from "std/collections";
import { Mutex } from "std/sync";
import { thread } from "std/thread";
import {
  ServiceHandler,
  ServiceInvocation,
  ServiceOutcome,
} from "../../../native/z/framework/service-contract.zs";
import { Service } from "../../../native/z/framework/services.zs";

export struct Note {
  id: u64;
  title: String;
}

struct NotesState {
  nextId: u64;
}

export struct CreateNoteInput {
  title: String;
}

struct NotesDecodeError {
  message: String;
}

export readonly struct NotesService implements Service {
  readonly state: Mutex<NotesState>;

  function create(input: CreateNoteInput): Note {
    const { title } = move input;
    const id = this.state.withLock((inout state): u64 => {
      state.nextId = state.nextId + 1;
      return state.nextId - 1;
    });
    return Note({ id, title: move title });
  }

  function count(): u64 {
    return this.state.withLock((in state): u64 => state.nextId - 1);
  }

  function handler(move this): ServiceHandler {
    return createNotesHandler(move this);
  }
}

export function createNotesService(): NotesService {
  return NotesService({
    state: Mutex(NotesState({ nextId: 1 })),
  });
}

function invalidArguments(message: String): ServiceOutcome {
  return ServiceOutcome.failure(`INVALID_ARGUMENTS: ${message}`);
}

function notesDecodeError(message: String): NotesDecodeError {
  return NotesDecodeError({ message: move message });
}

function decodeCreateNoteInput(
  in source: String
): CreateNoteInput throws NotesDecodeError {
  const parsed = attempt parse(in source);
  match (parsed) {
    failure(error) => throw notesDecodeError(copy error.message);
    success(value) => match (value) {
      object(fields) => {
        const found = fields.get("title");
        match (in found) {
          some(field) => match (in field) {
            string(title) => return CreateNoteInput({ title: copy title });
            nullValue => throw notesDecodeError("title must be a string");
            boolean(_) => throw notesDecodeError("title must be a string");
            number(_) => throw notesDecodeError("title must be a string");
            array(_) => throw notesDecodeError("title must be a string");
            object(_) => throw notesDecodeError("title must be a string");
          }
          none => throw notesDecodeError("missing required field title");
        }
      }
      nullValue => throw notesDecodeError("arguments must be an object");
      boolean(_) => throw notesDecodeError("arguments must be an object");
      number(_) => throw notesDecodeError("arguments must be an object");
      string(_) => throw notesDecodeError("arguments must be an object");
      array(_) => throw notesDecodeError("arguments must be an object");
    }
  }
}

function encodeNote(note: Note): String {
  const { id, title } = move note;
  let fields = Map<String, JsonValue>();
  fields.set("id", JsonValue.string(`${id}`));
  fields.set("title", JsonValue.string(move title));
  const value = JsonValue.object(move fields);
  return stringify(in value);
}

function encodeNoteCount(count: u64): String {
  let fields = Map<String, JsonValue>();
  fields.set("count", JsonValue.string(`${count}`));
  const value = JsonValue.object(move fields);
  return stringify(in value);
}

function invokeNotesService(
  in service: NotesService,
  in invocation: ServiceInvocation
): ServiceOutcome on thread.any {
  if (invocation.method == "create") {
    const decoded = attempt decodeCreateNoteInput(in invocation.arguments);
    return match (decoded) {
      success(input) => {
        const note = service.create(move input);
        select ServiceOutcome.success(encodeNote(move note));
      }
      failure(error) => invalidArguments(copy error.message);
    };
  }
  if (invocation.method == "count") {
    return ServiceOutcome.success(encodeNoteCount(service.count()));
  }
  return ServiceOutcome.failure("UNKNOWN_METHOD");
}

function createNotesHandler(service: NotesService): ServiceHandler {
  return move (
    in invocation: ServiceInvocation
  ): ServiceOutcome => invokeNotesService(in service, in invocation);
}
