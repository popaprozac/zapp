function requireAdapter(adapter) {
  if (!adapter || typeof adapter.list !== "function" || typeof adapter.create !== "function") {
    throw new TypeError("Z Notes requires a list/create framework adapter");
  }
  return adapter;
}

function renderNotes(notes) {
  const list = document.querySelector("#notes");
  list.replaceChildren(...notes.map((note) => {
    const item = document.createElement("li");
    const title = document.createElement("strong");
    const body = document.createElement("span");
    title.textContent = note.title;
    body.textContent = note.body;
    item.dataset.noteId = note.id;
    item.append(title, body);
    return item;
  }));
  document.body.dataset.noteCount = String(notes.length);
}

export async function mountNotesApp(candidate, harness = null) {
  const adapter = requireAdapter(candidate);
  const form = document.querySelector("#create-note");
  const title = document.querySelector("#title");
  const body = document.querySelector("#body");
  const submit = document.querySelector("#submit");
  const status = document.querySelector("#status");

  async function refresh() {
    const notes = await adapter.list();
    renderNotes(notes);
    return notes;
  }

  async function create(input) {
    const note = await adapter.create(input);
    await refresh();
    return note;
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    submit.disabled = true;
    status.textContent = "Saving…";
    try {
      await create({ title: title.value, body: body.value });
      title.value = "";
      body.value = "";
      status.textContent = "Saved";
      document.body.dataset.lastOperation = "create";
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : String(error);
      document.body.dataset.lastOperation = "error";
    } finally {
      submit.disabled = false;
    }
  });

  globalThis.__zNotesBenchmark = {
    async run(iterations = 10) {
      const started = performance.now();
      for (let index = 0; index < iterations; index += 1) {
        await create({
          title: `Benchmark note ${index + 1}`,
          body: `Created by the shared Z Notes workflow at iteration ${index + 1}.`,
        });
      }
      const durationMs = performance.now() - started;
      const result = { iterations, durationMs };
      document.body.dataset.benchmark = "complete";
      globalThis.__zNotesBenchmarkResult = result;
      return result;
    },
  };

  await refresh();
  document.body.dataset.ready = "true";
  status.textContent = "Ready";

  if (harness?.enabled) {
    await harness.ready();
    const workflow = await globalThis.__zNotesBenchmark.run(
      harness.iterations ?? 10,
    );
    const probes = typeof harness.probe === "function"
      ? await harness.probe()
      : undefined;
    const result = probes ? { ...workflow, probes } : workflow;
    await harness.complete(result);
  }
}
