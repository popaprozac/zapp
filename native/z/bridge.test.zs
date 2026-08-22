import { routeMessage } from "./bridge.zs";
import { expect } from "std/test";

test "routes a typed ping envelope" {
  const routed = routeMessage(
    '{"t":1,"id":18446744073709551615,"m":"__zapp:ping","a":{"message":"héllo from Zapp"}}'
  );
  const maximum: u64 = 18446744073709551615;
  match (routed) {
    some(response) => {
      expect(response.id).toEqual(maximum);
      expect(response.ok).toEqual(true);
      expect(response.payload).toEqual('{"message":"héllo from Zapp"}');
    }
    none => expect(false).toEqual(true);
  }
}

test "rejects malformed and unknown bridge messages" {
  const zero: u64 = 0;
  const requestId: u64 = 42;
  const malformed = routeMessage("{");
  match (malformed) {
    some(response) => {
      expect(response.id).toEqual(zero);
      expect(response.ok).toEqual(false);
      expect(response.payload).toEqual("expected a string key in JSON object");
    }
    none => expect(false).toEqual(true);
  }

  const unknown = routeMessage('{"t":1,"id":42,"m":"missing","a":{}}');
  match (unknown) {
    some(response) => {
      expect(response.id).toEqual(requestId);
      expect(response.ok).toEqual(false);
      expect(response.payload).toEqual("UNKNOWN_METHOD");
    }
    none => expect(false).toEqual(true);
  }
}

test "does not answer fire-and-forget bridge actions" {
  const ready = routeMessage('{"t":4,"m":"ready","a":{}}');
  match (ready) {
    some(_) => expect(false).toEqual(true);
    none => expect(true).toEqual(true);
  }
}
