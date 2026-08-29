import { mountNotesApp } from "../../../shared/app.js";

const notes = globalThis.__zappServices.notes;

await mountNotesApp({
  async list() {
    const page = await notes.list();
    return JSON.parse(page.notesJson);
  },
  async create(input) {
    const note = await notes.create(input);
    return { ...note, id: note.id.toString() };
  },
});
