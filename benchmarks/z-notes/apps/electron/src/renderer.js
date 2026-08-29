import { mountNotesApp } from "./shared/app.js";

await mountNotesApp({
  list: () => globalThis.zNotes.list(),
  create: (input) => globalThis.zNotes.create(input),
});
