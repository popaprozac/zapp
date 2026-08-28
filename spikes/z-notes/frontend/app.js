const button = document.querySelector("#ping");
const cancelButton = document.querySelector("#cancel");
const status = document.querySelector("#status");
const services = globalThis.__zappServices;

// Vite replaces `import.meta.hot` in production and supplies the live HMR
// client in development. The native smoke verifies the matching mode, proving
// that `zapp dev` loaded the app through Vite rather than a stale packaged UI.
document.body.dataset.hmr = import.meta.hot ? "ready" : "packaged";

const currentWindowId = globalThis[Symbol.for("zapp.windowId")];
if (currentWindowId === "win-1") {
  services.windows.openDiagnostics().then((opened) => {
    document.body.dataset.dynamicWindow =
      opened ? "ready" : "error";
  }).catch(() => {
    document.body.dataset.dynamicWindow = "error";
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
  const expectsDiagnostics = windowId === "win-2";
  const isolated = expectsDiagnostics
    ? diagnostics === "ready"
    : diagnostics === undefined;
  document.body.dataset.windowId = String(windowId ?? "missing");
  document.body.dataset.inject =
    start === "ready" && end === "ready" && style === "ready" && isolated
      ? "ready"
      : "error";
}, 0);

button.addEventListener("click", async () => {
  status.textContent = "Routing…";
  try {
    const note = await services.notes.create({ title: "WebView note" });
    const empty = await services.notes.isEmpty();
    if (empty) throw new Error("Expected the created note");
    const health = await services.health.status();
    if (health !== "ready") {
      throw new Error(`Unexpected health status: ${health}`);
    }
    status.textContent = `Created note ${note.id}\n${note.title}`;
    document.body.dataset.roundTrip = "ok";
    document.body.dataset.health = "ok";
  } catch (error) {
    status.textContent = `Failure\n${String(error)}`;
    document.body.dataset.roundTrip = "error";
  }
});

cancelButton.addEventListener("click", async () => {
  status.textContent = "Starting cancellable work…";
  const controller = new AbortController();
  const pending = services.notes.count({ signal: controller.signal });
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
      const note = await services.notes.create({ title: "WebView note" });
      const empty = await services.notes.isEmpty();
      if (empty) throw new Error("Expected the created note");
      const health = await services.health.status();
      if (health !== "ready") {
        throw new Error(`Unexpected health status: ${health}`);
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
