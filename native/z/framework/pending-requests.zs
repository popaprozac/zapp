import { TaskControl } from "std/async";
import { Map } from "std/collections";
import { thread } from "std/thread";

class PendingRequest {
  readonly id: u64;
  generation: u64;
  control: Option<TaskControl>;
  completed: boolean;

  function attach(
    inout this,
    control: TaskControl
  ): void on thread.main {
    if (this.completed) return;
    this.control = Option.some(control);
  }

  function finish(inout this): void on thread.main {
    this.completed = true;
    this.control = Option.none;
  }

  function requestCancel(inout this): boolean on thread.main {
    this.completed = true;
    const requested = match (in this.control) {
      some(control) => control.requestCancel();
      none => false;
    };
    this.control = Option.none;
    return requested;
  }

  function hasSameGeneration(
    generation: u64
  ): boolean on thread.main {
    return this.generation == generation;
  }
}

export class PendingRequests on thread.main {
  requests: Map<u64, PendingRequest>;
  nextGeneration: u64;

  function begin(
    inout this,
    id: u64
  ): u64 {
    const generation = this.nextGeneration;
    this.nextGeneration = this.nextGeneration + 1;
    const request = new PendingRequest({
      id,
      generation,
      control: Option<TaskControl>.none,
      completed: false,
    });
    const previous = this.requests.remove(id);
    match (previous) {
      some(value) => {
        let active = value;
        active.requestCancel();
      }
      none => {}
    }
    this.requests.set(id, request);
    return generation;
  }

  function attach(
    inout this,
    id: u64,
    control: TaskControl
  ): void {
    const found = this.requests.remove(id);
    match (found) {
      some(value) => {
        let request = value;
        request.attach(control);
        this.requests.set(id, request);
      }
      none => {}
    }
  }

  function finish(
    inout this,
    id: u64,
    generation: u64
  ): void {
    const found = this.requests.remove(id);
    match (found) {
      some(value) => {
        let request = value;
        if (request.hasSameGeneration(generation)) {
          request.finish();
          return;
        }
        this.requests.set(id, request);
      }
      none => {}
    }
  }

  function cancel(
    inout this,
    id: u64
  ): boolean {
    const found = this.requests.remove(id);
    return match (found) {
      some(value) => {
        let request = value;
        select request.requestCancel();
      }
      none => false;
    };
  }
}

export function createPendingRequests(): PendingRequests on thread.main {
  return new PendingRequests({
    requests: Map<u64, PendingRequest>(),
    nextGeneration: 1,
  });
}
