import { expect, fail } from "std/test";
import { Note, NoteState } from "./notes-core.zs";
import {
  decodeNotesDocument,
  encodeNotesDocument,
} from "./notes-transfer.zs";

test "portable note documents round-trip content without database identity" {
  const notes = Array<Note>(
    Note({
      id: 42,
      title: "A portable note",
      subtitle: "Moved between Zapp applications",
      state: NoteState.archived,
    })
  );
  const source = encodeNotesDocument(in notes);

  const decoded = attempt decodeNotesDocument(in source);
  match (decoded) {
    success(notes) => {
      expect(notes.length).toEqual(1);
      expect(notes[0].title).toEqual("A portable note");
      expect(notes[0].state == NoteState.archived).toEqual(true);
      match (in notes[0].subtitle) {
        some(subtitle) => expect(in subtitle).toEqual(
          "Moved between Zapp applications"
        );
        none => fail("expected the portable subtitle");
      }
    }
    failure(error) => fail(copy error.message);
  }
}
