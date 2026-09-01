import {
  createWindow,
  currentWindow,
} from "@zappdev/runtime/window";
import {
  health,
  NoteCreationError,
  NoteDescription,
  notes,
} from "zapp:services";

const button = document.querySelector("#ping");
const cancelButton = document.querySelector("#cancel");
const renameWindowButton = document.querySelector("#rename-window");
const hideWindowButton = document.querySelector("#hide-window");
const closeWindowButton = document.querySelector("#close-window");
const status = document.querySelector("#status");

// Vite replaces `import.meta.hot` in production and supplies the live HMR
// client in development. The native smoke verifies the matching mode, proving
// that `zapp dev` loaded the app through Vite rather than a stale packaged UI.
document.body.dataset.hmr = import.meta.hot ? "ready" : "packaged";

const windowHandle = currentWindow();
const currentWindowId = windowHandle.id;
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
    status.textContent = `Created note ${note.id}\n${note.title}`;
    windowHandle.setTitle(`Z Notes — ${note.title}`);
    document.body.dataset.roundTrip = "ok";
    document.body.dataset.health = "ok";
  } catch (error) {
    status.textContent = `Failure\n${String(error)}`;
    document.body.dataset.roundTrip = "error";
  }
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
