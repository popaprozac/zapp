import { Map } from "std/collections";
import { Mutex } from "std/sync";
import {
  ApplicationSecondInstanceLaunchedEvent,
  decodeApplicationLaunch,
  validApplicationLaunch,
} from "./application-launch.zs";

internal enum ActivationRequest {
  reopen,
  openURL String,
  secondInstance ApplicationSecondInstanceLaunchedEvent,
}

// One process-local budget shared by OS activation and secondary launches.
// No callbacks or executor hops run while this state is locked.
internal struct ActivationInboxState {
  pending: Map<usize, ActivationRequest>;
  head: usize;
  tail: usize;
  count: usize;
  closed: boolean;
}

internal readonly class ActivationInbox {
  private readonly state: Mutex<ActivationInboxState>;

  internal constructor() {
    this.state = Mutex(ActivationInboxState({
      pending: Map<usize, ActivationRequest>(),
      head: 0,
      tail: 0,
      count: 0,
      closed: false,
    }));
  }

  function enqueue(request: ActivationRequest): boolean {
    return this.state.withLock(move (inout state): boolean => {
      if (state.closed || state.count == 64) return false;
      state.pending.set(state.tail, move request);
      state.tail = (state.tail + 1) % 64;
      state.count = state.count + 1;
      return true;
    });
  }

  function admit(launch: ApplicationSecondInstanceLaunchedEvent): boolean {
    if (!validApplicationLaunch(in launch)) return false;
    return this.enqueue(ActivationRequest.secondInstance(move launch));
  }

  // The native boundary can acknowledge this result without running app code.
  // Decode first with the existing version/size checks, then atomically admit or
  // reject against the same capacity and closed state used by the main executor.
  function admitPayload(in payload: String): boolean {
    return match (attempt decodeApplicationLaunch(in payload)) {
      success(launch) => this.admit(move launch);
      failure(_) => false;
    };
  }

  function take(): Option<ActivationRequest> {
    return this.state.withLock((inout state): Option<ActivationRequest> => {
      if (state.closed || state.count == 0) return Option<ActivationRequest>.none;
      const request = state.pending.remove(state.head);
      state.head = (state.head + 1) % 64;
      state.count = state.count - 1;
      return move request;
    });
  }

  function isClosed(): boolean {
    return this.state.withLock((in state): boolean => state.closed);
  }

  function close(): void {
    this.state.withLock((inout state): void => {
      state.closed = true;
      state.pending = Map<usize, ActivationRequest>();
      state.head = 0;
      state.tail = 0;
      state.count = 0;
    });
  }
}
