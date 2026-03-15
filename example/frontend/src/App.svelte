<script lang="ts">
  import { App, Events, Sync } from '@zapp/runtime';
  import svelteLogo from './assets/svelte.svg'
  import viteLogo from '/vite.svg'

  let name = $state("");
  let greetMsg = $state("");
  let syncKey = $state("demo-sync");
  let waitTimeoutMs = $state(15000);
  let waitForever = $state(false);
  let notifyCount = $state(1);
  let syncStatus = $state("");
  let syncLog = $state<string[]>([]);
  let waitController = $state<AbortController | null>(null);

  async function greet(event: Event) {
    event.preventDefault();
    Events.emit("ping", { name });
    greetMsg = `Hello, ${name}!`;
  }

  function appendSyncLog(line: string): void {
    const stamped = `[${new Date().toLocaleTimeString()}] ${line}`;
    syncLog = [stamped, ...syncLog].slice(0, 8);
  }

  async function handleSyncWait(event: Event): Promise<void> {
    event.preventDefault();
    waitController?.abort("superseded");
    const controller = new AbortController();
    waitController = controller;
    syncStatus = `Waiting on "${syncKey}"...`;
    appendSyncLog(
      waitForever
        ? `wait("${syncKey}", { timeoutMs: null }) started`
        : `wait("${syncKey}", ${waitTimeoutMs}) started`
    );
    try {
      const result = await Sync.wait(syncKey, {
        timeoutMs: waitForever ? null : waitTimeoutMs,
        signal: controller.signal,
      });
      syncStatus = `Wait completed: ${result}`;
      appendSyncLog(`wait("${syncKey}") -> ${result}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      syncStatus = `Wait failed: ${message}`;
      appendSyncLog(`wait("${syncKey}") failed: ${message}`);
    } finally {
      if (waitController === controller) {
        waitController = null;
      }
    }
  }

  function handleSyncNotify(event: Event): void {
    event.preventDefault();
    const ok = Sync.notify(syncKey, notifyCount);
    syncStatus = ok
      ? `notify("${syncKey}", ${notifyCount}) sent`
      : `notify("${syncKey}", ${notifyCount}) unavailable`;
    appendSyncLog(syncStatus);
  }

  function handleSyncCancel(event: Event): void {
    event.preventDefault();
    if (waitController == null) {
      syncStatus = "No active wait to cancel.";
      appendSyncLog(syncStatus);
      return;
    }
    waitController.abort("user-cancel");
    syncStatus = "Cancel requested for active wait.";
    appendSyncLog(syncStatus);
  }
</script>

<main class="container">
  <h1>Welcome to Zapp + Svelte</h1>

  <div class="row">
    <a href="https://vitejs.dev" target="_blank" rel="noreferrer">
      <img src={viteLogo} class="logo vite" alt="Vite Logo" />
    </a>
    <a href="https://svelte.dev" target="_blank" rel="noreferrer">
      <img src={svelteLogo} class="logo svelte" alt="Svelte Logo" />
    </a>
  </div>
  <p>Click on the Vite and Svelte logos to learn more.</p>

  <form class="row" onsubmit={greet}>
    <input id="greet-input" placeholder="Enter a name..." bind:value={name} />
    <button type="submit">Greet</button>
  </form>
  <p>{greetMsg}</p>

  <section class="sync-panel">
    <h2>Sync.wait / Sync.notify demo</h2>
    <p class="sync-help">
      Open two windows: run <code>wait</code> in one and <code>notify</code> in the other.
    </p>
    <div class="sync-row">
      <input placeholder="sync key" bind:value={syncKey} />
      <input
        type="number"
        min="1"
        max="300000"
        bind:value={waitTimeoutMs}
        disabled={waitForever}
      />
      <label class="wait-forever">
        <input type="checkbox" bind:checked={waitForever} />
        infinite
      </label>
      <button onclick={handleSyncWait}>Wait</button>
      <button onclick={handleSyncCancel}>Cancel</button>
    </div>
    <div class="sync-row">
      <input type="number" min="1" max="65535" bind:value={notifyCount} />
      <button onclick={handleSyncNotify}>Notify</button>
    </div>
    <p class="sync-status">{syncStatus}</p>
    <div class="sync-log">
      {#if syncLog.length === 0}
        <div class="sync-log-line">No sync actions yet.</div>
      {:else}
        {#each syncLog as line}
          <div class="sync-log-line">{line}</div>
        {/each}
      {/if}
    </div>
  </section>
</main>

<style>
.logo.vite:hover {
  filter: drop-shadow(0 0 2em #747bff);
}

.logo.svelte:hover {
  filter: drop-shadow(0 0 2em #ff3e00);
}

.container {
  margin: 0;
  padding-top: 10vh;
  display: flex;
  flex-direction: column;
  justify-content: center;
  text-align: center;
}

.logo {
  height: 6em;
  padding: 1.5em;
  will-change: filter;
  transition: 0.3s;
}

.row {
  display: flex;
  justify-content: center;
}

a {
  font-weight: 500;
  color: #646cff;
  text-decoration: inherit;
}

a:hover {
  color: #535bf2;
}

h1 {
  text-align: center;
}

input,
button {
  border-radius: 8px;
  border: 1px solid transparent;
  padding: 0.6em 1.2em;
  font-size: 1em;
  font-weight: 500;
  font-family: inherit;
  color: #0f0f0f;
  background-color: #ffffff;
  transition: border-color 0.25s;
  box-shadow: 0 2px 2px rgba(0, 0, 0, 0.2);
}

button {
  cursor: pointer;
}

button:hover {
  border-color: #396cd8;
}
button:active {
  border-color: #396cd8;
  background-color: #e8e8e8;
}

input,
button {
  outline: none;
}

#greet-input {
  margin-right: 5px;
}

.sync-panel {
  margin: 1.5rem auto 0;
  width: min(680px, 92vw);
  border: 1px solid #d5d5d5;
  border-radius: 10px;
  padding: 1rem;
  text-align: left;
}

.sync-help,
.sync-status {
  margin: 0.5rem 0;
}

.sync-row {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.5rem;
}

.sync-row input {
  flex: 1;
}

.wait-forever {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  white-space: nowrap;
}

.sync-log {
  margin-top: 0.75rem;
  padding: 0.6rem;
  border-radius: 8px;
  border: 1px solid #e2e2e2;
  max-height: 180px;
  overflow: auto;
}

.sync-log-line {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono",
    "Courier New", monospace;
  font-size: 0.85rem;
  line-height: 1.4;
}

@media (prefers-color-scheme: dark) {
  input,
  button {
    color: #ffffff;
    background-color: #0f0f0f98;
  }
  button:active {
    background-color: #0f0f0f69;
  }
  .sync-panel,
  .sync-log {
    border-color: #3a3a3a;
  }
}
</style>