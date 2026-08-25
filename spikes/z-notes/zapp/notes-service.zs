import { thread } from "std/thread";
import { scheduler } from "std/async";
import {
  ServiceInvocation,
  ServiceOutcome,
} from "../../../native/z/framework/service-contract.zs";
import { AsyncService } from "../../../native/z/framework/async-service-contract.zs";
import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
} from "../../../native/z/framework/service-lifecycle-contract.zs";
import {
  CreateNoteInput,
  Note,
  NotesCore,
  createNotesCore,
  invokeNotesCore,
} from "./notes-core.zs";
import console from "std/console";

export readonly class NotesService implements AsyncService, ServiceLifecycle {
  readonly core: NotesCore;

  function create(input: CreateNoteInput): Note {
    return this.core.create(move input);
  }

  function count(): u64 {
    return this.core.count();
  }

  async function invoke(
    in invocation: ServiceInvocation
  ): ServiceOutcome {
    await scheduler.yield();
    const core = this.core;
    return invokeNotesCore(in core, in invocation);
  }

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    console.log(`${context.name}: notes service started`);
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    console.log(`${context.name}: notes service stopped`);
  }
}

export function createNotesService(): NotesService {
  return new NotesService({ core: createNotesCore() });
}
