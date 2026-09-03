import {
  ApplicationError,
  ApplicationState,
  ApplicationStateError,
} from "./application-error.zs";
import { OnceState } from "std/sync";

internal function requireApplicationPublicationState(
  state: OnceState
): void throws ApplicationError {
  match (state) {
    empty => {}
    initialized => throw ApplicationError.state(
      ApplicationStateError({
        state: ApplicationState.running,
        message: "Another Application.run() is already active in this process",
      })
    );
    closed => throw ApplicationError.state(
      ApplicationStateError({
        state: ApplicationState.stopped,
        message: "Application.run() cannot publish a new application after process shutdown",
      })
    );
  }
}
