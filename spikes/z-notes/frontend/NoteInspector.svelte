<script lang="ts">
  import type { NotesModel } from "./notes-model";
  let { model, close }: { model: NotesModel; close: () => void } = $props();
  let view = $derived(model.state);
  let note = $derived($view.items.find(item => String(item.id) === $view.selectedId));
</script>

<main class="inspector" data-note-inspector>
  <header data-zapp-drag-region>
    <span class="inspector-icon" aria-hidden="true">i</span>
    <div><p class="eyebrow">Z Notes</p><h1>Note inspector</h1></div>
    <span class="connected"><span aria-hidden="true"></span>Live</span>
  </header>
  <p class="hint">A shared view of your note. Changes stay in sync with the editor.</p>
  {#if note}
    <section class="details" aria-label="Note metadata">
      <h2>Details</h2>
      <dl>
        <div><dt>Note ID</dt><dd class="identifier" data-inspector-id>#{String(note.id)}</dd></div>
        <div><dt>State</dt><dd><span class="badge">{note.state}</span></dd></div>
        <div><dt>Subtitle</dt><dd>{note.subtitle || "No subtitle"}</dd></div>
        <div><dt>Title characters</dt><dd>{Array.from(note.draftTitle).length}</dd></div>
        <div><dt>Changes</dt><dd class:unsaved={note.title !== note.draftTitle} data-inspector-dirty>{note.title === note.draftTitle ? "Saved" : "Unsaved edits"}</dd></div>
      </dl>
    </section>
    <section class="edit" aria-label="Edit note">
      <label for="inspector-title">Title</label>
      <input id="inspector-title" value={note.draftTitle}
        oninput={event => model.setTitle(note!.id, event.currentTarget.value)} />
      <button class="primary" type="button" disabled={$view.busy || note.title === note.draftTitle}
        onclick={() => model.save(note!.id)}>Save through Z service</button>
    </section>
  {:else}
    <p>Create or select a note in Z Notes to inspect it here.</p>
  {/if}
  {#if $view.error}<p role="alert">{$view.error}</p>{/if}
  <footer><span>Shared selection · independent window</span><button type="button" onclick={close}>Close inspector</button></footer>
</main>
