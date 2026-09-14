<script lang="ts">
  import type { NotesModel, EditableNote } from "./notes-model";
  import type { InspectorManager } from "./related-inspectors";
  let { model, inspectors, createNote, showActions }: {
    model: NotesModel; inspectors: InspectorManager; createNote: () => Promise<void>;
    showActions: (note: EditableNote, input: HTMLInputElement, x: number, y: number) => void;
  } = $props();
  let view = $derived(model.state);
  let inspectorState = $derived(inspectors.state);
  let creating = $state(false);
  async function create() {
    if (creating) return;
    creating = true;
    try { await createNote(); } finally { creating = false; }
  }
</script>

<section aria-label="Notes workspace" data-svelte-notes>
  <form class="controls" onsubmit={event => { event.preventDefault(); void create(); }}>
    <input id="note-title" aria-label="New note title" value={$view.draftTitle}
      oninput={event => model.setDraftTitle(event.currentTarget.value)} />
    <button id="ping" type="submit" disabled={creating}>Create a note in Z</button>
  </form>
  <ul id="notes" aria-live="polite">
    {#each $view.items as note (note.id)}
      {@const selected = String(note.id) === $view.selectedId}
      <li class:selected data-selected-note={selected ? String(note.id) : undefined} aria-current={selected ? "true" : undefined}
        oncontextmenu={event => {
          // Preserve the native text-editing menu inside inputs.
          if ((event.target as Element).closest('input, textarea, [contenteditable]')) return;
          event.preventDefault();
          showActions(note, event.currentTarget.querySelector('input')!, event.clientX, event.clientY);
        }}>
        <button class="select-note" type="button" onclick={() => model.select(note.id)}>
          <strong>{note.draftTitle || "Untitled"}</strong><small>#{String(note.id)} · {note.state}{note.subtitle ? ` · ${note.subtitle}` : ""}</small>
        </button>
        <input aria-label={`Title for note ${note.id}`} value={note.draftTitle}
          onfocus={() => model.select(note.id)} oninput={event => model.setTitle(note.id, event.currentTarget.value)} />
        <div class="note-actions">
          <button type="button" disabled={$view.busy} onclick={() => model.save(note.id)}>Save</button>
          <button type="button" disabled={$view.busy || note.state === "archived"} onclick={() => model.archive(note.id)}>{note.state === "archived" ? "Archived" : "Archive"}</button>
          <button type="button" disabled={$view.busy} onclick={() => model.remove(note.id)}>Delete</button>
          <button type="button" aria-haspopup="menu" aria-label={`Actions for note ${note.id}`}
            onclick={event => {
              const button = event.currentTarget;
              const input = button.closest('li')!.querySelector('input')!;
              const bounds = button.getBoundingClientRect();
              showActions(note, input, bounds.left, Math.min(bounds.bottom, button.ownerDocument.defaultView!.innerHeight - 1));
            }}>Actions…</button>
        </div>
      </li>
    {/each}
  </ul>
  {#if $view.loaded && !$view.items.length}<p>No notes yet. Create one to get started.</p>{/if}
  {#if $view.error}<p role="alert">{$view.error}</p>{/if}
  <h2>Related note inspectors</h2>
  <div class="controls">
    <button id="related-inspector" type="button" disabled={$inspectorState.opening} onclick={() => inspectors.open()}>Open note inspector</button>
    <button id="close-inspectors" type="button" onclick={() => inspectors.closeAll()}>Close inspectors</button>
  </div>
  <p id="related-status">{$inspectorState.error || `${$inspectorState.count} inspector(s) share this Svelte state. Select a note, then edit its title in either window.`}</p>
</section>

<style>
  .controls, .note-actions { display: flex; flex-wrap: wrap; gap: 10px; }
  input { min-width: 0; box-sizing: border-box; width: 100%; padding: 10px 12px;
    border: 1px solid #80808060; border-radius: 8px; background: transparent; color: inherit; font: inherit; }
  .controls input { flex: 1 1 220px; width: auto; }
  button { padding: 8px 12px; font: inherit; cursor: pointer; }
  #notes { display: grid; gap: 12px; margin: 16px 0; padding: 0; list-style: none; }
  li { display: grid; gap: 10px; padding: 14px; background: #80808018; border: 2px solid transparent; border-radius: 10px; }
  li.selected { border-color: Highlight; } .select-note { display: grid; gap: 4px; text-align: left; padding: 0; color: inherit; background: none; border: none; }
  small, #related-status { opacity: .7; } h2 { font-size: 16px; margin-top: 24px; }
  [role="alert"] { color: light-dark(#ad2222, #ffaaaa); }
</style>
