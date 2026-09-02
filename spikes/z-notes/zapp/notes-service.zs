import { thread } from "std/thread";
import { delay } from "std/time";
import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
} from "zapp/service";
import {
  CreateNoteInput,
  Note,
  NoteDescription,
  NoteState,
  NotesCore,
  createNotesCore,
} from "./notes-core.zs";
import console from "std/console";

export struct NoteCreationError {
  message: String;
  title: String;
}

class NotesCatalog on thread.main {
  notes: Array<Note>;

  function add(inout this, note: Note): void {
    this.notes.push(move note);
  }

  function list(): Array<Note> {
    return copy this.notes;
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
    catalog: new NotesCatalog({ notes: Array<Note>() }),
  });
}
