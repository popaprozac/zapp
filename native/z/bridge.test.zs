import { routeMessage } from "./bridge.zs";
import { expect } from "std/test";

test "routes a typed ping envelope" {
  const response = routeMessage(
    '{"t":1,"id":18446744073709551615,"m":"__zapp:ping","a":{"message":"héllo from Zapp"}}'
  );
  const maximum: u64 = 18446744073709551615;
  expect(response.id).toEqual(maximum);
  expect(response.ok).toEqual(true);
  expect(response.payload).toEqual('{"message":"héllo from Zapp"}');
}

test "rejects malformed and unknown bridge messages" {
  const zero: u64 = 0;
  const requestId: u64 = 42;
  const malformed = routeMessage("{");
  expect(malformed.id).toEqual(zero);
  expect(malformed.ok).toEqual(false);
  expect(malformed.payload).toEqual("expected a string key in JSON object");

  const unknown = routeMessage('{"t":1,"id":42,"m":"missing","a":{}}');
  expect(unknown.id).toEqual(requestId);
  expect(unknown.ok).toEqual(false);
  expect(unknown.payload).toEqual("UNKNOWN_METHOD");
}
