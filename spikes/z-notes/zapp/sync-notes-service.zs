import {
  ServiceInvocation,
  ServiceOutcome,
} from "../../../native/z/framework/service-contract.zs";
import { Service } from "../../../native/z/framework/services.zs";
import {
  CreateNoteInput,
  Note,
  NotesCore,
  createNotesCore,
  invokeNotesCore,
} from "./notes-core.zs";

export readonly class SyncNotesService implements Service {
  readonly core: NotesCore;

  function create(input: CreateNoteInput): Note {
    return this.core.create(move input);
  }

  function count(): u64 {
    return this.core.count();
  }

  function invoke(in invocation: ServiceInvocation): ServiceOutcome {
    const core = this.core;
    return invokeNotesCore(in core, in invocation);
  }
}

export function createSyncNotesService(): SyncNotesService {
  return new SyncNotesService({ core: createNotesCore() });
}
