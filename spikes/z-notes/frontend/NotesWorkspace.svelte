<script lang="ts">
  import { onMount } from "svelte";
  import { currentWindow, WindowEvent } from "@zappdev/runtime/window";
  import type { NotesModel, EditableNote } from "./notes-model";
  import type { InspectorManager } from "./related-inspectors";
  let { model, inspectors, createNote, showActions }: {
    model: NotesModel; inspectors: InspectorManager; createNote: () => Promise<void>;
    showActions: (note: EditableNote, input: HTMLInputElement, x: number, y: number) => void;
  } = $props();
  let view = $derived(model.state);
  let inspectorState = $derived(inspectors.state);
  let creating = $state(false);
  let search = $state("");
  let fileDragging = $state(false);
  onMount(() => {
    const window = currentWindow();
    const subscriptions = [
      window.subscribe(WindowEvent.FILE_DRAG_ENTERED, () => { fileDragging = true; }),
      window.subscribe(WindowEvent.FILE_DRAG_MOVED, () => { fileDragging = true; }),
      window.subscribe(WindowEvent.FILE_DRAG_ENDED, () => { fileDragging = false; }),
    ];
    return () => { subscriptions.forEach(subscription => subscription.unsubscribe()); };
  });
  let query = $derived(search.trim().toLocaleLowerCase());
  let visibleNotes = $derived($view.items.filter(note => !query
    || `${note.draftTitle}\n${note.subtitle ?? ""}\n${note.id}`.toLocaleLowerCase().includes(query)));
  async function create() {
    if (creating) return;
    creating = true;
    try { await createNote(); } finally { creating = false; }
  }
</script>

{#if fileDragging}
  <div class="file-drop-overlay" role="status" data-file-drop-highlight>
    <div class="file-drop-prompt">
      <strong>Drop text files to create notes</strong>
      <span>Existing UTF-8 files · the filename becomes the title</span>
    </div>
  </div>
{/if}

<section aria-label="Notes workspace" data-svelte-notes>
  <header class="workspace-header" data-zapp-titlebar>
    <div class="workspace-heading"><h1>Z Notes</h1><span>{$view.items.length} notes</span></div>
    <input id="note-search" type="search" aria-label="Search notes" placeholder="Search notes" bind:value={search} />
    <button id="related-inspector" type="button" disabled={$inspectorState.opening} onclick={() => inspectors.open()}>Inspector</button>
  </header>
  <div class="workspace-content">
  <p class="workspace-description">Notes are owned by a Z service and persisted in SQLite.</p>
  <form class="controls" onsubmit={event => { event.preventDefault(); void create(); }}>
    <input id="note-title" aria-label="New note title" value={$view.draftTitle}
      oninput={event => model.setDraftTitle(event.currentTarget.value)} />
    <button id="ping" type="submit" disabled={creating}>Create a note in Z</button>
  </form>
  <ul id="notes" aria-live="polite">
    {#each visibleNotes as note (note.id)}
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
  {#if $view.loaded && $view.items.length && !visibleNotes.length}<p data-empty-search>No notes match “{search}”.</p>{/if}
  {#if $view.error}<p role="alert">{$view.error}</p>{/if}
  <h2>Related note inspectors</h2>
  <div class="controls">
    <button id="close-inspectors" type="button" onclick={() => inspectors.closeAll()}>Close inspectors</button>
  </div>
  <p id="related-status">{$inspectorState.error || `${$inspectorState.count} inspector(s) share this Svelte state. Select a note, then edit its title in either window.`}</p>
  </div>
</section>

<style>
  .file-drop-overlay {
    position: fixed; z-index: 100; pointer-events: none;
    inset: max(12px, var(--zapp-titlebar-height, 0px)) 12px 12px;
    display: grid; place-items: center; padding: 24px;
    border: 2px dashed light-dark(#2865c7, #9cbfff); border-radius: 14px;
    background: light-dark(rgb(223 236 255 / 85%), rgb(32 53 83 / 90%));
  }
  .file-drop-prompt { display: grid; gap: 8px; text-align: center; }
  .file-drop-prompt strong { font-size: 20px; }
  .file-drop-prompt span { font-size: 13px; opacity: .8; }
  section { display: contents; }
  .workspace-header {
    position: sticky; top: 0; z-index: 1;
    display: flex; align-items: center; gap: 12px; box-sizing: border-box;
    min-height: max(66px, var(--zapp-titlebar-height, 0px));
    padding: 10px 20px 10px calc(var(--zapp-window-controls-inset-left, 0px) + 16px);
    border-bottom: 1px solid light-dark(#d8dfe9, #394355);
    background: light-dark(#edf2f9, #232c3c); user-select: none;
  }
  .workspace-heading { display: flex; align-items: baseline; gap: 10px; flex: 1; min-width: 90px; }
  h1 { margin: 0; font-size: 19px; font-weight: 650; letter-spacing: -.5px; white-space: nowrap; }
  .workspace-heading span { color: light-dark(#657286, #aebbcf); font-size: 12px; white-space: nowrap; }
  .workspace-header input { width: clamp(110px, 24vw, 240px); flex: 0 1 240px; padding: 7px 10px; }
  .workspace-header button { flex-shrink: 0; padding: 7px 11px; }
  .workspace-content { max-width: 760px; margin: auto; padding: 0 24px 24px; }
  .workspace-description { color: light-dark(#657286, #aebbcf); font-size: 13px; margin: 20px 0; }
  @media (max-width: 620px) { .workspace-heading span { display: none; } }
  @media (max-width: 440px) {
    .workspace-header { flex-wrap: wrap; gap: 8px; padding-top: max(14px, var(--zapp-titlebar-height, 0px)); padding-left: 16px; }
    .workspace-heading { flex-basis: 100%; }
    .workspace-header input { flex: 1; }
  }
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
