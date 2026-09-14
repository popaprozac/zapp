import { get, writable } from "svelte/store";

// A presentation snapshot, structurally satisfied by generated service types.
// The Z service remains the persistent owner; this model owns unsaved UI edits.
export interface NoteSnapshot {
  id: bigint;
  title: string;
  subtitle?: string | null;
  state: "active" | "archived";
}
export interface EditableNote extends NoteSnapshot { draftTitle: string }
export interface NotesService {
  list(): Promise<NoteSnapshot[]>;
  edit(input: { id: bigint; title: string; subtitle?: string | null }): Promise<unknown>;
  archive(input: { id: bigint }): Promise<unknown>;
  delete(input: { id: bigint }): Promise<unknown>;
}

export function createNotesModel(service: NotesService, selectedId: string | null = null) {
  const state = writable({
    items: [] as EditableNote[], selectedId, draftTitle: "WebView note",
    busy: false, loaded: false, error: "",
  });
  let revision = 0;
  async function refresh() {
    const request = ++revision;
    const items = await service.list();
    if (request !== revision) return;
    state.update(current => {
      const previous = new Map(current.items.map(note => [String(note.id), note]));
      return { ...current, loaded: true,
        selectedId: items.some(note => String(note.id) === current.selectedId)
          ? current.selectedId : items[0] ? String(items[0].id) : null,
        items: items.map(note => {
          const old = previous.get(String(note.id));
          return { ...note, draftTitle: old && old.title !== old.draftTitle ? old.draftTitle : note.title };
        }),
      };
    });
  }
  async function mutate(id: bigint, operation: "save" | "archive" | "delete") {
    const current = get(state);
    const note = current.items.find(item => item.id === id);
    // All documents share this gate. A second click never submits a duplicate.
    if (!note || current.busy) return;
    state.update(value => ({ ...value, busy: true, error: "" }));
    try {
      if (operation === "save") {
        const title = note.draftTitle.trim();
        await service.edit({ id, title, subtitle: note.subtitle });
        state.update(value => ({ ...value, items: value.items.map(item => item.id !== id ? item : {
          ...item, title, draftTitle: item.draftTitle === note.draftTitle ? title : item.draftTitle,
        }) }));
      } else if (operation === "archive") await service.archive({ id });
      else await service.delete({ id });
      await refresh();
    } catch (error) {
      state.update(value => ({ ...value, error: error instanceof Error ? error.message : String(error) }));
    } finally { state.update(value => ({ ...value, busy: false })); }
  }
  return {
    state: { subscribe: state.subscribe },
    refresh,
    select(id: bigint) { state.update(value => ({ ...value, selectedId: String(id) })); },
    setTitle(id: bigint, draftTitle: string) {
      state.update(value => ({ ...value, items: value.items.map(note => note.id === id ? { ...note, draftTitle } : note) }));
    },
    getDraftTitle() { return get(state).draftTitle; },
    setDraftTitle(draftTitle: string) { state.update(value => ({ ...value, draftTitle })); },
    save: (id: bigint) => mutate(id, "save"),
    archive: (id: bigint) => mutate(id, "archive"),
    remove: (id: bigint) => mutate(id, "delete"),
  };
}
export type NotesModel = ReturnType<typeof createNotesModel>;
