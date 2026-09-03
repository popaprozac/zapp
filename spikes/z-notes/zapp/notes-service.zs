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
  CreateNoteInput,
  Note,
  NoteDescription,
  NoteState,
  NotesCore,
  createNotesCore,
} from "./notes-core.zs";
import {
  NoteDatabase,
  NotesStorage,
  createNotesStorage,
} from "./notes-persistence.zs";
import console from "std/console";
import fs from "std/fs";

export struct NoteCreationError {
  message: String;
  title: String;
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

  function configureDataDirectory(inout this, path: String): void {
    this.dataDirectory = move path;
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
