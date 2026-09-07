import { expect, fail } from "std/test";
import { noteIdFromURL } from "./notes-route.zs";

test "note activation accepts explicit routes with exact u64 identity" {
  match (noteIdFromURL("ZNOTES://NOTES/42")) {
    some(id) => expect(id).toEqual(42);
    none => fail("valid custom URL did not parse");
  }
  match (noteIdFromURL("znotes://notes/18446744073709551615")) {
    some(id) => expect(id).toEqual(18446744073709551615);
    none => fail("maximum u64 ID did not parse");
  }
}

test "note activation rejects overflow, extra routes, and executable input" {
  const rejected = Array<String>(
    "znotes://notes/0", "znotes://notes/", "znotes://notes/-1",
    "znotes://notes/18446744073709551616", "znotes://notes/999999999999999999999",
    "znotes://notes/1?method=delete", "znotes://notes/1#fragment",
    "znotes://notes/%31", "znotes://notes/../1", "znotes://notes.evil/1",
    "file:///notes/1", "https://notes/1", "javascript:alert(1)"
  );
  for (const url of rejected) {
    match (noteIdFromURL(in url)) {
      some(_) => fail("unsafe or unsupported route was accepted");
      none => {}
    }
  }
}
