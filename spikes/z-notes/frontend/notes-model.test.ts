import { describe, expect, test } from "bun:test";
import { get } from "svelte/store";
import { createNotesModel, type NoteSnapshot, type NotesService } from "./notes-model";

function fixture() {
  let items: NoteSnapshot[] = [
    { id: 1n, title: "First", state: "active" },
    { id: 2n, title: "Second", state: "active", subtitle: "Details" },
  ];
  const service: NotesService = {
    async list() { return items.map(item => ({ ...item })); },
    async edit(input) { items = items.map(item => item.id === input.id ? { ...item, ...input } : item); },
    async archive({ id }) { items = items.map(item => item.id === id ? { ...item, state: "archived" } : item); },
    async delete({ id }) { items = items.filter(item => item.id !== id); },
  };
  return { service, model: createNotesModel(service, "2") };
}

describe("shared Svelte notes presentation", () => {
  test("keeps exact bigint IDs and the requested selection", async () => {
    const { model } = fixture();
    await model.refresh();
    expect(get(model.state).selectedId).toBe("2");
    expect(get(model.state).items[0].id).toBe(1n);
  });
  test("shares edits with multiple subscribers without persisting until save", async () => {
    const { model, service } = fixture();
    await model.refresh();
    let first = "", second = "";
    const a = model.state.subscribe(value => { first = value.items[0].draftTitle; });
    const b = model.state.subscribe(value => { second = value.items[0].draftTitle; });
    model.setTitle(1n, "Draft");
    expect([first, second]).toEqual(["Draft", "Draft"]);
    expect((await service.list())[0].title).toBe("First");
    a(); model.setTitle(1n, "Newer"); expect(first).toBe("Draft"); expect(second).toBe("Newer"); b();
  });
  test("refresh preserves unsaved text, including edits made during save", async () => {
    const { model, service } = fixture();
    await model.refresh(); model.setTitle(1n, "Submitted");
    let resolve!: () => void;
    const edit = service.edit;
    service.edit = async input => { await new Promise<void>(done => { resolve = done; }); await edit(input); };
    const saving = model.save(1n);
    model.setTitle(1n, "Still typing"); resolve(); await saving;
    expect(get(model.state).items[0]).toMatchObject({ title: "Submitted", draftTitle: "Still typing" });
  });
  test("a successful save clears dirty state and trims the saved title", async () => {
    const { model } = fixture(); await model.refresh(); model.setTitle(1n, "  Saved  "); await model.save(1n);
    expect(get(model.state).items[0]).toMatchObject({ title: "Saved", draftTitle: "Saved" });
  });
  test("errors are shared and the mutation gate releases", async () => {
    const { model, service } = fixture(); await model.refresh();
    service.edit = async () => { throw new Error("Native save failed"); };
    model.setTitle(1n, "Keep this"); await model.save(1n);
    expect(get(model.state)).toMatchObject({ busy: false, error: "Native save failed" });
    expect(get(model.state).items[0].draftTitle).toBe("Keep this");
  });
  test("duplicate requests from different documents submit only once", async () => {
    const { model, service } = fixture(); await model.refresh();
    let calls = 0, resolve!: () => void;
    service.archive = async () => { calls++; await new Promise<void>(done => { resolve = done; }); };
    const pending = model.archive(1n); await model.archive(1n); expect(calls).toBe(1); resolve(); await pending;
  });
  test("selection follows deletion and the last deletion empties the inspector", async () => {
    const { model } = fixture(); await model.refresh(); await model.remove(2n);
    expect(get(model.state).selectedId).toBe("1"); await model.remove(1n);
    expect(get(model.state)).toMatchObject({ selectedId: null, items: [] });
  });
  test("a slower obsolete list response cannot overwrite newer data", async () => {
    const { model, service } = fixture();
    let resolve!: (value: NoteSnapshot[]) => void;
    service.list = () => new Promise(done => { resolve = done; });
    const old = model.refresh(); service.list = async () => [{ id: 3n, title: "Newest", state: "active" }];
    await model.refresh(); resolve([{ id: 1n, title: "Stale", state: "active" }]); await old;
    expect(get(model.state).items[0].title).toBe("Newest");
  });
});
