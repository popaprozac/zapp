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

  function configureDataDirectory(inout this, path: String): void {
    this.dataDirectory = move path;
  }
}

export readonly class NotesService implements ServiceLifecycle {
  readonly core: NotesCore;
  readonly catalog: NotesCatalog;

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
    catalog.configureDataDirectory(copy context.paths.data);
    console.log(`${context.metadata.name}: notes service started`);
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
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
  });
}
