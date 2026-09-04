import {
  createWindow,
  currentWindow,
  WindowEvent,
} from "@zappdev/runtime/window";
import {
  health,
  NoteCreationError,
  NoteMutationError,
  NoteDescription,
  notes,
} from "zapp:services";
import { noteIndexer } from "zapp:workers";

const button = document.querySelector("#ping");
const cancelButton = document.querySelector("#cancel");
const indexButton = document.querySelector("#index-notes");
const renameWindowButton = document.querySelector("#rename-window");
const hideWindowButton = document.querySelector("#hide-window");
const closeWindowButton = document.querySelector("#close-window");
const noteTitle = document.querySelector("#note-title");
const noteList = document.querySelector("#notes");
const status = document.querySelector("#status");
const windowEvents = document.querySelector("#window-events");
const workerIndex = document.querySelector("#worker-index");

function renderNotes(items) {
  noteList.replaceChildren(...items.map((note) => {
    const item = document.createElement("li");
    const title = document.createElement("strong");
    const details = document.createElement("small");
    title.textContent = note.title;
    details.textContent = [
      `#${note.id}`,
      note.state,
      note.subtitle,
    ].filter(Boolean).join(" · ");
    const titleInput = document.createElement("input");
    const actions = document.createElement("div");
    const save = document.createElement("button");
    const archive = document.createElement("button");
    const remove = document.createElement("button");
    titleInput.value = note.title;
    titleInput.setAttribute("aria-label", `Title for note ${note.id}`);
    actions.className = "note-actions";
    save.type = "button";
    save.textContent = "Save";
    archive.type = "button";
    archive.textContent = note.state === "archived" ? "Archived" : "Archive";
    archive.disabled = note.state === "archived";
    remove.type = "button";
    remove.textContent = "Delete";

    const mutate = async (operation) => {
      actions.querySelectorAll("button").forEach((button) => {
        button.disabled = true;
      });
      try {
        await operation();
        await refreshNotes();
      } catch (error) {
        status.textContent = error instanceof NoteMutationError
          ? `Could not change note ${error.details?.id}\n${error.details?.message}`
          : `Could not change note\n${String(error)}`;
        actions.querySelectorAll("button").forEach((button) => {
          button.disabled = false;
        });
      }
    };

    save.addEventListener("click", () => mutate(() => notes.edit({
      id: note.id,
      title: titleInput.value.trim(),
      subtitle: note.subtitle,
    })));
    archive.addEventListener("click", () => mutate(() => notes.archive({
      id: note.id,
    })));
    remove.addEventListener("click", () => mutate(() => notes.delete({
      id: note.id,
    })));

    actions.append(save, archive, remove);
    item.append(title, details, titleInput, actions);
    return item;
  }));
  document.body.dataset.notesLoaded = "ok";
}

async function refreshNotes() {
  renderNotes(await notes.list());
}

// Vite replaces `import.meta.hot` in production and supplies the live HMR
// client in development. The native smoke verifies the matching mode, proving
// that `zapp dev` loaded the app through Vite rather than a stale packaged UI.
document.body.dataset.hmr = import.meta.hot ? "ready" : "packaged";

const windowHandle = currentWindow();
const currentWindowId = windowHandle.id;
let focusedEvents = 0;
let blurredEvents = 0;
let resizedEvents = 0;
let latestSize = "waiting";

function renderWindowEvents() {
  windowEvents.textContent = [
    `Window: ${currentWindowId}`,
    `Focused: ${focusedEvents}`,
    `Blurred: ${blurredEvents}`,
    `Resized: ${resizedEvents}`,
    `Latest size: ${latestSize}`,
  ].join("\n");
}

windowHandle.subscribe(WindowEvent.FOCUS, () => {
  focusedEvents += 1;
  renderWindowEvents();
});
windowHandle.subscribe(WindowEvent.BLUR, () => {
  blurredEvents += 1;
  renderWindowEvents();
});
windowHandle.subscribe(WindowEvent.RESIZE, (event) => {
  resizedEvents += 1;
  latestSize = `${event.size.width} × ${event.size.height}`;
  renderWindowEvents();
});
renderWindowEvents();

let nextIndexRequest = 1;

noteIndexer.messages.subscribe((message) => {
  switch (message.kind) {
    case "started":
      workerIndex.textContent = `Worker started index ${message.value.requestId}`;
      break;
    case "progress":
      workerIndex.textContent = [
        `Index ${message.value.requestId}`,
        `${message.value.completed}/${message.value.total}: ${message.value.title}`,
      ].join("\n");
      break;
    case "complete":
      workerIndex.textContent = [
        `Indexed ${message.value.total} note${message.value.total === 1 ? "" : "s"}`,
        `Active: ${message.value.active}; archived: ${message.value.archived}`,
        `Title characters: ${message.value.titleCharacters}`,
      ].join("\n");
      document.body.dataset.workerIndex = "ok";
      break;
    case "failed":
      workerIndex.textContent = `Worker index failed\n${message.value.message}`;
      document.body.dataset.workerIndex = "error";
      break;
  }
});

indexButton.addEventListener("click", async () => {
  const requestId = `webview-${nextIndexRequest}`;
  nextIndexRequest += 1;
  workerIndex.textContent = `Queueing index ${requestId}…`;
  try {
    await noteIndexer.commands.indexNotes({ requestId });
  } catch (error) {
    workerIndex.textContent = `Worker unavailable\n${String(error)}`;
    document.body.dataset.workerIndex = "error";
  }
});

if (currentWindowId === "win-1") {
  createWindow({
    title: "Z Notes Diagnostics",
    url: "/diagnostics",
    width: 480,
    height: 320,
  }).then((created) => {
    document.body.dataset.dynamicWindow = created.id === "win-2"
      ? "ready"
      : "error";
  }).catch((error) => {
    document.body.dataset.dynamicWindow = "error";
    status.textContent = `Window failure\n${String(error)}`;
  });
} else {
  document.body.dataset.dynamicWindow = "ready";
}

setTimeout(() => {
  const windowId = currentWindowId;
  const start = globalThis[Symbol.for("zapp.inject.base.start")];
  const diagnostics = globalThis[Symbol.for("zapp.inject.diagnostics")];
  const end = document.documentElement.dataset.zappInjectEnd;
  const style = getComputedStyle(document.documentElement)
    .getPropertyValue("--zapp-inject-base")
    .trim();
  const expectsBase = windowId === "win-1";
  const isolated = expectsBase
    ? start === "ready"
      && end === "ready"
      && style === "ready"
      && diagnostics === undefined
    : start === undefined
      && end === undefined
      && style === ""
      && diagnostics === undefined;
  document.body.dataset.windowId = String(windowId ?? "missing");
  document.body.dataset.inject = isolated ? "ready" : "error";
}, 0);

renameWindowButton.addEventListener("click", () => {
  const title = `Z Notes — ${currentWindowId}`;
  windowHandle.setTitle(title);
  status.textContent = `Renamed native window\n${title}`;
});

hideWindowButton.addEventListener("click", () => {
  status.textContent = "Hiding native window for 1 second…";
  windowHandle.hide();
  setTimeout(() => {
    windowHandle.show();
    status.textContent = "Native window shown again";
  }, 1000);
});

closeWindowButton.addEventListener("click", () => {
  status.textContent = `Closing ${currentWindowId}…`;
  windowHandle.close();
});

async function verifyTypedServiceError() {
  try {
    await notes.create({ title: "", state: "active" });
    throw new Error("Expected typed NoteCreationError");
  } catch (error) {
    if (
      !(error instanceof NoteCreationError)
      || error?.details?.message !== "a note title is required"
    ) {
      throw error;
    }
    document.body.dataset.typedError = "ok";
  }
}

async function verifyPayloadEnum() {
  const description = await notes.describeState("active");
  const expected = NoteDescription.described("Editable");
  if (description.kind !== expected.kind || description.value !== expected.value) {
    throw new Error(`Unexpected note description: ${JSON.stringify(description)}`);
  }
  if (!(await notes.hasDescription(description))) {
    throw new Error("Expected the payload enum to round-trip through Z");
  }
  document.body.dataset.payloadEnum = "ok";
}

button.addEventListener("click", async () => {
  status.textContent = "Routing…";
  try {
    await verifyTypedServiceError();
    const title = noteTitle.value.trim();
    const note = await notes.create({ title, state: "active" });
    if (note.subtitle !== null) {
      throw new Error(`Expected an omitted subtitle, received ${note.subtitle}`);
    }
    if (note.state !== "active") {
      throw new Error(`Expected active note state, received ${note.state}`);
    }
    if (await notes.isArchived("active")) {
      throw new Error("Expected active note to remain editable");
    }
    await verifyPayloadEnum();
    const empty = await notes.isEmpty();
    if (empty) throw new Error("Expected the created note");
    const healthStatus = await health.status();
    if (healthStatus !== "ready") {
      throw new Error(`Unexpected health status: ${healthStatus}`);
    }
    status.textContent = `Created note ${note.id}\n${note.title}`;
    await refreshNotes();
    windowHandle.setTitle(`Z Notes — ${note.title}`);
    document.body.dataset.roundTrip = "ok";
    document.body.dataset.health = "ok";
  } catch (error) {
    status.textContent = `Failure\n${String(error)}`;
    document.body.dataset.roundTrip = "error";
  }
});

noteTitle.addEventListener("keydown", (event) => {
  if (event.key === "Enter") button.click();
});

cancelButton.addEventListener("click", async () => {
  status.textContent = "Starting cancellable work…";
  try {
    await verifyTypedServiceError();
  } catch (error) {
    status.textContent = `Failure\n${String(error)}`;
    document.body.dataset.cancellation = "error";
    return;
  }
  const controller = new AbortController();
  const pending = notes.count({ signal: controller.signal });
  controller.abort("smoke cancellation");
  try {
    await pending;
    status.textContent = "Failure\nCancelled request resolved";
    document.body.dataset.cancellation = "error";
  } catch (error) {
    if (error?.name !== "AbortError") {
      status.textContent = `Failure\n${String(error)}`;
      document.body.dataset.cancellation = "error";
      return;
    }
    document.body.dataset.cancellation = "ok";
    status.textContent = "Cancelled safely; checking follow-up…";
    try {
      const note = await notes.create({ title: "WebView note", state: "active" });
      if (note.subtitle !== null) {
        throw new Error(`Expected an omitted subtitle, received ${note.subtitle}`);
      }
      if (note.state !== "active") {
        throw new Error(`Expected active note state, received ${note.state}`);
      }
      if (await notes.isArchived("active")) {
        throw new Error("Expected active note to remain editable");
      }
      await verifyPayloadEnum();
      const empty = await notes.isEmpty();
      if (empty) throw new Error("Expected the created note");
      const healthStatus = await health.status();
      if (healthStatus !== "ready") {
        throw new Error(`Unexpected health status: ${healthStatus}`);
      }
      await refreshNotes();
      status.textContent =
        `Cancelled safely\nCreated note ${note.id}\n${note.title}`;
      document.body.dataset.roundTrip = "ok";
      document.body.dataset.health = "ok";
    } catch (followUpError) {
      status.textContent = `Failure\n${String(followUpError)}`;
      document.body.dataset.roundTrip = "error";
    }
  }
});

refreshNotes().catch((error) => {
  status.textContent = `Could not load notes\n${String(error)}`;
  document.body.dataset.notesLoaded = "error";
});
