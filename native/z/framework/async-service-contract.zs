import {
  ServiceInvocation,
  ServiceOutcome,
} from "./service-contract.zs";
import { Map } from "std/collections";
import { replace } from "std/memory";
import { thread } from "std/thread";

export type AsyncServiceHandler =
  async (in invocation: ServiceInvocation) => ServiceOutcome on thread.any;

export trait AsyncService {
  async function invoke(in invocation: ServiceInvocation): ServiceOutcome;
}

export struct AsyncServiceRegistry {
  handlers: Map<String, AsyncServiceHandler>;

  function add(
    inout this,
    name: String,
    handler: AsyncServiceHandler
  ): void {
    this.handlers.set(move name, handler);
  }

  function freeze(
    move this
  ): readonly Map<String, AsyncServiceHandler> {
    const { handlers } = move this;
    return handlers.freeze();
  }

  internal function take(
    inout this
  ): readonly Map<String, AsyncServiceHandler> {
    const replacement = Map<String, AsyncServiceHandler>();
    const handlers = replace(inout this.handlers, move replacement);
    return handlers.freeze();
  }
}

export function createAsyncServiceRegistry(): AsyncServiceRegistry {
  return AsyncServiceRegistry({
    handlers: Map<String, AsyncServiceHandler>(),
  });
}
