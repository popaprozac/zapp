import { expect } from "std/test";
import { OnceState } from "std/sync";
import {
  requireApplicationPublicationState,
} from "../framework/application-publication.zs";

test "rejects a second active Application with a typed state error" {
  const result = attempt requireApplicationPublicationState(
    OnceState.initialized
  );
  match (result) {
    success => expect(false).toEqual(true);
    failure(error) => {
      match (error) {
        state(detail) => {
          expect(detail.message).toEqual(
            "Another Application.run() is already active in this process"
          );
        }
        _ => expect(false).toEqual(true);
      }
    }
  }
}

test "rejects Application publication after process shutdown" {
  const result = attempt requireApplicationPublicationState(OnceState.closed);
  match (result) {
    success => expect(false).toEqual(true);
    failure(error) => {
      match (error) {
        state(detail) => {
          expect(detail.message).toEqual(
            "Application.run() cannot publish a new application after process shutdown"
          );
        }
        _ => expect(false).toEqual(true);
      }
    }
  }
}
