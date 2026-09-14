<script lang="ts">
  import type { NotesModel } from "./notes-model";
  let { model, close }: { model: NotesModel; close: () => void } = $props();
  let view = $derived(model.state);
  let note = $derived($view.items.find(item => String(item.id) === $view.selectedId));
</script>

<main class="inspector" data-note-inspector>
  <header><p class="eyebrow">Z Notes · Svelte</p><h1>Note inspector</h1></header>
  <p class="hint">One frontend owner. Selection and unsaved edits are shared with the editor.</p>
  {#if note}
    <dl>
      <dt>Note ID</dt><dd data-inspector-id>{String(note.id)}</dd>
      <dt>State</dt><dd>{note.state}</dd>
      <dt>Subtitle</dt><dd>{note.subtitle || "No subtitle"}</dd>
      <dt>Title characters</dt><dd>{Array.from(note.draftTitle).length}</dd>
      <dt>Changes</dt><dd data-inspector-dirty>{note.title === note.draftTitle ? "Saved" : "Unsaved edits"}</dd>
    </dl>
    <label for="inspector-title">Title</label>
    <input id="inspector-title" value={note.draftTitle}
      oninput={event => model.setTitle(note!.id, event.currentTarget.value)} />
    <button type="button" disabled={$view.busy || note.title === note.draftTitle}
      onclick={() => model.save(note!.id)}>Save through Z service</button>
  {:else}
    <p>Create or select a note in Z Notes to inspect it here.</p>
  {/if}
  {#if $view.error}<p role="alert">{$view.error}</p>{/if}
  <footer><button type="button" onclick={close}>Close inspector</button></footer>
</main>
