import { expect } from "std/test";
import {
  createSyncNotesService,
} from "../../../spikes/z-notes/zapp/sync-notes-service.zs";
import { createServices } from "../framework/services.zs";

test "registers one value service and preserves its state" {
  let builder = createServices();
  builder.register("notes", createSyncNotesService());
  const services = builder.freeze();

  const created = services.invoke(
    "notes.create",
    '{"title":"Z service test"}'
  );
  match (created) {
    success(payload) => expect(payload).toEqual(
      '{"id":"1","title":"Z service test"}'
    );
    failure(_) => expect(false).toEqual(true);
  }

  const counted = services.invoke("notes.count", "{}");
  match (counted) {
    success(payload) => expect(payload).toEqual('{"count":"1"}');
    failure(_) => expect(false).toEqual(true);
  }
}

test "returns typed service failures without changing the routing table" {
  let builder = createServices();
  builder.register("notes", createSyncNotesService());
  const services = builder.freeze();

  const invalid = services.invoke("notes.create", "{}");
  match (invalid) {
    success(_) => expect(false).toEqual(true);
    failure(message) => expect(message).toEqual(
      "INVALID_ARGUMENTS: missing required field title"
    );
  }

  const missing = services.invoke("missing.call", "{}");
  match (missing) {
    success(_) => expect(false).toEqual(true);
    failure(message) => expect(message).toEqual("UNKNOWN_METHOD");
  }
}
