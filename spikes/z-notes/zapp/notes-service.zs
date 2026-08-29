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
  NotesCore,
  createNotesCore,
} from "./notes-core.zs";
import console from "std/console";

export struct NoteCreationError {
  message: String;
  title: String;
}

export readonly class NotesService implements ServiceLifecycle {
  readonly core: NotesCore;

  function create(input: CreateNoteInput): Note throws NoteCreationError {
    if (input.title.byteLength == 0) {
      throw NoteCreationError({
        message: "a note title is required",
        title: "",
      });
    }
    return this.core.create(move input);
  }

  async function count(): u64 on thread.main {
    await delay(1);
    return this.core.count();
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

export function createNotesService(): NotesService {
  return new NotesService({ core: createNotesCore() });
}
