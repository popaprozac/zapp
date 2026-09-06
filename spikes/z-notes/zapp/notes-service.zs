import { thread } from "std/thread";
import { delay } from "std/time";
import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
  ServiceLifecyclePhase,
} from "zapp/service";
import { Application } from "zapp";
import {
  DialogError,
  FileFilter,
  OpenDialogOptions,
  SaveDialogOptions,
} from "zapp/dialog";
import { FileError } from "zapp/files";
import {
  CreateNoteInput,
  EditNoteInput,
  Note,
  NoteDescription,
  NoteReference,
  NoteState,
  NotesCore,
  createNotesCore,
} from "./notes-core.zs";
import {
  NoteDatabase,
  NotesStorage,
  createNotesStorage,
} from "./notes-persistence.zs";
import {
  decodeNotesDocument,
  encodeNotesDocument,
} from "./notes-transfer.zs";
import console from "std/console";
import fs from "std/fs";

export struct NoteCreationError {
  message: String;
  title: String;
}

export struct NoteMutationError {
  id: u64;
  message: String;
}

export enum NoteTransferOperation {
  importFile,
  exportFile,
}

export struct NoteTransferError {
  operation: NoteTransferOperation;
  message: String;
}

export struct NoteTransfer {
  path: String;
  count: u64;
}

class NotesCatalog on thread.main {
  notes: Array<Note>;
  dataDirectory: String;

  function add(inout this, note: Note): void {
    this.notes.push(move note);
  }

  function list(): Array<Note> {
    return copy this.notes;
  }

  function replaceAll(inout this, notes: Array<Note>): void {
    this.notes = move notes;
  }

  function get(id: u64): Option<Note> {
    for (const note of this.notes) {
      if (note.id == id) return Option.some(copy note);
    }
    return Option.none;
  }

  function replace(inout this, note: Note): boolean {
    let index: usize = 0;
    while (index < this.notes.length) {
      if (this.notes[index].id == note.id) {
        this.notes[index] = move note;
        return true;
      }
      index = index + 1;
    }
    return false;
  }

  function remove(inout this, id: u64): Option<Note> {
    let remaining = Array<Note>();
    let removed: Option<Note> = Option.none;
    for (const note of this.notes) {
      if (note.id == id) removed = Option.some(copy note);
      else remaining.push(copy note);
    }
    this.notes = move remaining;
    return removed;
  }

  function configureDataDirectory(inout this, path: String): void {
    this.dataDirectory = move path;
  }

  function directory(): String {
    return copy this.dataDirectory;
  }
}

export readonly class NotesService implements ServiceLifecycle {
  readonly core: NotesCore;
  readonly catalog: NotesCatalog;
  readonly storage: NotesStorage;

  async function create(
    input: CreateNoteInput
  ): Note throws NoteCreationError on thread.main {
    await delay(1);
    if (input.title.byteLength == 0) {
      throw NoteCreationError({
        message: "a note title is required",
        title: "",
      });
    }
    const note = this.core.create(move input);
    const catalog = this.catalog;
    const stored = attempt this.storage.insert(in note);
    match (stored) {
      success => {}
      failure(status) => {
        this.core.revertLastCreate(note.id);
        throw NoteCreationError({
          message: `could not persist note: sqlite status ${status}`,
          title: copy note.title,
        });
      }
    }
    catalog.add(copy note);
    return note;
  }

  function count(): u64 on thread.main {
    return this.core.count();
  }

  function list(): Array<Note> on thread.main {
    return this.catalog.list();
  }

  async function importFile(
  ): Option<NoteTransfer> throws NoteTransferError on thread.main {
    const application = Application.current();
    const defaultPath = this.catalog.directory();
    const selected = attempt await application.dialogs.openFile(
      OpenDialogOptions({
        title: "Import Z Notes",
        defaultPath: move defaultPath,
        filters: Array<FileFilter>(FileFilter({
          name: "JSON",
          extensions: Array<String>("json"),
        })),
      })
    );
    const selection = match (selected) {
      success(value) => value;
      failure(error) => throw transferDialogError(
        NoteTransferOperation.importFile,
        in error
      );
    };
    const path = match (selection) {
      some(value) => value;
      none => return Option<NoteTransfer>.none;
    };
    const loaded = attempt await application.files.readText(in path);
    const source = match (loaded) {
      success(value) => value;
      failure(error) => throw transferFileError(
        NoteTransferOperation.importFile,
        in error
      );
    };
    const decoded = attempt decodeNotesDocument(in source);
    const inputs = match (decoded) {
      success(value) => value;
      failure(error) => throw noteTransferError(
        NoteTransferOperation.importFile,
        copy error.message
      );
    };

    const previous = this.catalog.list();
    let newNotes = Array<Note>();
    for (const input of inputs) {
      newNotes.push(this.core.create(copy input));
    }
    const stored = attempt this.storage.insertMany(in newNotes);
    match (stored) {
      success => {}
      failure(status) => {
        this.core.restore(in previous);
        throw noteTransferError(
          NoteTransferOperation.importFile,
          `could not persist imported notes: sqlite status ${status}`
        );
      }
    }
    const catalog = this.catalog;
    for (const note of newNotes) {
      catalog.add(copy note);
    }
    return Option.some(NoteTransfer({
      path: move path,
      count: u64(newNotes.length),
    }));
  }

  async function exportFile(
  ): Option<NoteTransfer> throws NoteTransferError on thread.main {
    const notes = this.catalog.list();
    const source = encodeNotesDocument(in notes);
    const application = Application.current();
    const defaultPath = this.catalog.directory();
    const selected = attempt await application.dialogs.saveFile(
      SaveDialogOptions({
        title: "Export Z Notes",
        defaultPath: move defaultPath,
        defaultName: "z-notes.json",
        filters: Array<FileFilter>(FileFilter({
          name: "JSON",
          extensions: Array<String>("json"),
        })),
      })
    );
    const selection = match (selected) {
      success(value) => value;
      failure(error) => throw transferDialogError(
        NoteTransferOperation.exportFile,
        in error
      );
    };
    const path = match (selection) {
      some(value) => value;
      none => return Option<NoteTransfer>.none;
    };
    const written = attempt await application.files.writeText(
      in path,
      in source
    );
    match (written) {
      success => {}
      failure(error) => throw transferFileError(
        NoteTransferOperation.exportFile,
        in error
      );
    }
    return Option.some(NoteTransfer({
      path: move path,
      count: u64(notes.length),
    }));
  }

  function edit(
    input: EditNoteInput
  ): Note throws NoteMutationError on thread.main {
    const { id, title, subtitle } = move input;
    if (title.byteLength == 0) throw NoteMutationError({
      id,
      message: "a note title is required",
    });
    const found = this.catalog.get(id);
    const existing = match (found) {
      some(note) => note;
      none => throw noteMutationError(id, "note not found");
    };
    const updated = Note({
      id,
      title: move title,
      subtitle: move subtitle,
      state: existing.state,
    });
    const stored = attempt this.storage.update(in updated);
    match (stored) {
      success => {}
      failure(status) => throw noteMutationError(
        id,
        `could not update note: sqlite status ${status}`
      );
    }
    const catalog = this.catalog;
    if (!catalog.replace(copy updated)) {
      throw noteMutationError(id, "note disappeared during update");
    }
    return updated;
  }

  function archive(
    reference: NoteReference
  ): Note throws NoteMutationError on thread.main {
    const found = this.catalog.get(reference.id);
    const existing = match (found) {
      some(note) => note;
      none => throw noteMutationError(reference.id, "note not found");
    };
    const archived = Note({
      copy ...existing,
      state: NoteState.archived,
    });
    const stored = attempt this.storage.update(in archived);
    match (stored) {
      success => {}
      failure(status) => throw noteMutationError(
        reference.id,
        `could not archive note: sqlite status ${status}`
      );
    }
    const catalog = this.catalog;
    if (!catalog.replace(copy archived)) {
      throw noteMutationError(reference.id, "note disappeared during archive");
    }
    return archived;
  }

  function delete(
    reference: NoteReference
  ): Note throws NoteMutationError on thread.main {
    const found = this.catalog.get(reference.id);
    const existing = match (found) {
      some(note) => note;
      none => throw noteMutationError(reference.id, "note not found");
    };
    const stored = attempt this.storage.delete(reference.id);
    match (stored) {
      success => {}
      failure(status) => throw noteMutationError(
        reference.id,
        `could not delete note: sqlite status ${status}`
      );
    }
    const catalog = this.catalog;
    const removed = catalog.remove(reference.id);
    match (removed) {
      some(_) => this.core.recordDelete();
      none => throw noteMutationError(
        reference.id,
        "note disappeared during deletion"
      );
    }
    return existing;
  }

  function isArchived(state: NoteState): boolean {
    return state == NoteState.archived;
  }

  function describeState(state: NoteState): NoteDescription {
    return match (state) {
      active => NoteDescription.described("Editable");
      archived => NoteDescription.unavailable;
    };
  }

  function hasDescription(description: NoteDescription): boolean {
    return match (description) {
      described(_) => true;
      unavailable => false;
    };
  }

  async function isEmpty(): boolean on thread.main {
    await delay(1);
    return this.core.count() == 0;
  }

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    const application = Application.current();
    const running = match (application.state()) {
      running => true;
      _ => false;
    };
    if (
      !running
      || application.metadata.identifier != context.metadata.identifier
    ) {
      throw ServiceLifecycleError({
        service: "notes",
        phase: ServiceLifecyclePhase.start,
        message: "current application identity was not published before startup",
      });
    }
    const directoryReady = attempt fs.createDirectories(context.paths.data);
    match (directoryReady) {
      success => {}
      failure(error) => throw ServiceLifecycleError({
        service: "notes",
        phase: ServiceLifecyclePhase.start,
        message: `could not prepare ${context.paths.data}: ${error}`,
      });
    }
    const catalog = this.catalog;
    const databasePath = `${context.paths.data}/notes.sqlite3`;
    const opened = attempt NoteDatabase.open(databasePath);
    const database = match (opened) {
      success(value) => value;
      failure(status) => throw ServiceLifecycleError({
        service: "notes",
        phase: ServiceLifecyclePhase.start,
        message: `could not open ${databasePath}: sqlite status ${status}`,
      });
    };
    const loaded = attempt database.loadNotes();
    let notes = match (loaded) {
      success(value) => value;
      failure(status) => throw ServiceLifecycleError({
        service: "notes",
        phase: ServiceLifecyclePhase.start,
        message: `could not load ${databasePath}: sqlite status ${status}`,
      });
    };
    this.core.restore(in notes);
    if (notes.length == 0) {
      const welcome = this.core.create(CreateNoteInput({
        title: "Welcome to Z Notes",
        subtitle: "Persisted by the application-owned SQLite service",
        state: NoteState.active,
      }));
      const seeded = attempt database.insertNote(in welcome);
      match (seeded) {
        success => notes.push(copy welcome);
        failure(status) => {
          this.core.revertLastCreate(welcome.id);
          throw ServiceLifecycleError({
            service: "notes",
            phase: ServiceLifecyclePhase.start,
            message: `could not seed ${databasePath}: sqlite status ${status}`,
          });
        }
      }
    }
    catalog.replaceAll(move notes);
    catalog.configureDataDirectory(copy context.paths.data);
    const storage = this.storage;
    storage.install(database);
    console.log(`${context.metadata.name}: notes service started`);
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    const storage = this.storage;
    storage.close();
    console.log(`${context.metadata.name}: notes service stopped`);
  }
}

export function createNotesService(): NotesService on thread.main {
  return new NotesService({
    core: createNotesCore(),
    catalog: new NotesCatalog({
      notes: Array<Note>(),
      dataDirectory: "",
    }),
    storage: createNotesStorage(),
  });
}

function noteMutationError(id: u64, message: String): NoteMutationError {
  return NoteMutationError({ id, message: move message });
}

function noteTransferError(
  operation: NoteTransferOperation,
  message: String
): NoteTransferError {
  return NoteTransferError({ operation, message: move message });
}

function transferDialogError(
  operation: NoteTransferOperation,
  in error: DialogError
): NoteTransferError {
  return noteTransferError(operation, copy error.message);
}

function transferFileError(
  operation: NoteTransferOperation,
  in error: FileError
): NoteTransferError {
  return noteTransferError(
    operation,
    `${error.path}: ${error.message}`
  );
}
