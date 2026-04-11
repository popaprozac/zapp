import "./style.css";
import {
  App,
  AppEvent,
  Window,
  WindowEvent,
  Events,
  Services,
  Dialog,
  Menu,
  ContextMenu,
  Notification,
  Worker,
  Dock,
  Sync
} from "@zappdev/runtime";
import { greet } from "./zapp";

// --- Setup ---

const win = Window.current();

const result = await greet({ name: "World" });
log(`greet({ name: "World" }) → ${result}`);

// --- Menu ---

Menu.build([
  {
    label: "File",
    submenu: [
      {
        label: "Open File...",
        accelerator: "CmdOrCtrl+O",
        action: async () => {
          const result = await Dialog.openFile({ title: "Open a file" });
          if (!result.cancelled) {
            log(`Opened: ${result.paths?.[0]}`);
          }
        },
      },
      { type: "separator" },
      { role: "quit" },
    ],
  },
  { role: "editMenu" },
  {
    label: "View",
    submenu: [
      {
        label: "Toggle Fullscreen",
        accelerator: "CmdOrCtrl+F",
        action: () => win.setFullscreen(true),
      },
    ],
  },
]);

// --- UI ---

document.querySelector<HTMLDivElement>("#app")!.innerHTML = `
  <div class="container">
    <h1>Zapp v2</h1>
    <p class="subtitle">Desktop framework — 354 KB binary</p>

    <div class="grid">
      <section>
        <h2>Services</h2>
        <input id="greet-input" type="text" placeholder="Enter name" value="World" />
        <button id="btn-greet">Invoke greet</button>
        <div id="greet-result" class="result"></div>
      </section>

      <section>
        <h2>Window</h2>
        <button id="btn-title">Set Title</button>
        <button id="btn-size">Resize 900x700</button>
        <button id="btn-minimize">Minimize</button>
        <button id="btn-guard">Enable Close Guard</button>
        <button id="btn-new-window">New Window</button>
        <button id="btn-new-window-small">New Window (small)</button>
      </section>

      <section>
        <h2>Sync (cross-context wait/notify)</h2>
        <button id="btn-sync-wait">Wait for "demo" (10s)</button>
        <button id="btn-sync-notify">Notify "demo" (one)</button>
        <button id="btn-sync-notify-all">Notify "demo" (all)</button>
        <div id="sync-result" class="result"></div>
      </section>

      <section>
        <h2>Dialogs</h2>
        <button id="btn-open-file">Open File</button>
        <button id="btn-save-file">Save File</button>
        <button id="btn-message">Message Dialog</button>
        <div id="dialog-result" class="result"></div>
      </section>

      <section>
        <h2>Notifications</h2>
        <button id="btn-notif-perm">Request Permission</button>
        <button id="btn-notif-show">Show</button>
        <button id="btn-notif-actions">With Actions</button>
        <button id="btn-notif-update">Update Last</button>
        <button id="btn-notif-remove">Remove Last</button>
        <button id="btn-notif-grouped">Grouped</button>
        <div id="notif-result" class="result"></div>
      </section>

      <section>
        <h2>Workers</h2>
        <button id="btn-worker-create">Create Worker</button>
        <button id="btn-worker-ping">Send Ping</button>
        <button id="btn-worker-service">Invoke Service</button>
        <button id="btn-worker-terminate">Terminate</button>
        <div id="worker-result" class="result"></div>
      </section>

      <section>
        <h2>Dock</h2>
        <button id="btn-dock-badge">Badge "3"</button>
        <button id="btn-dock-clear">Clear Badge</button>
        <button id="btn-dock-bounce">Bounce</button>
        <button id="btn-dock-hide">Hide Icon</button>
        <button id="btn-dock-show">Show Icon</button>
      </section>

      <section>
        <h2>Events</h2>
        <button id="btn-emit">Emit Custom Event</button>
        <div id="event-log" class="result"></div>
      </section>

      <section>
        <h2>Backend State</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          Backend ticks every 2s. Open multiple windows — they all update in lockstep
          from backend-owned state, no polling.
        </p>
        <div id="counter-display" class="result">Counter: (waiting…)</div>
      </section>

      <section>
        <h2>Other</h2>
        <button id="btn-external">Open zapp.dev</button>
        <button id="btn-ctx-menu">Right-click menu</button>
      </section>
    </div>

    <div id="log" class="log"></div>
  </div>
`;

// --- Helpers ---

function log(msg: string) {
  const el = document.getElementById("log");
  if (!el) { console.log(msg); return; }
  const line = document.createElement("div");
  line.textContent = `[${new Date().toLocaleTimeString()}] ${msg}`;
  el.prepend(line);
  while (el.children.length > 20) el.removeChild(el.lastChild!);
}

function $(id: string) {
  return document.getElementById(id)!;
}

// --- Services ---

$("btn-greet").addEventListener("click", async () => {
  const name = (document.getElementById("greet-input") as HTMLInputElement)
    .value;
  try {
    const result = await Services.invoke("greet", { name });
    $("greet-result").textContent = `Result: ${JSON.stringify(result)}`;
    log(`greet("${name}") → ${JSON.stringify(result)}`);
  } catch (e) {
    log(`greet error: ${e}`);
  }
});

// --- Window ---

$("btn-title").addEventListener("click", () => {
  win.setTitle("Hello from Zapp! " + Date.now());
  log("Title updated");
});

$("btn-size").addEventListener("click", () => {
  win.setSize(900, 700);
  log("Resized to 900x700");
});

$("btn-minimize").addEventListener("click", () => {
  win.minimize();
  log("Minimized");
});

$("btn-new-window").addEventListener("click", async () => {
  try {
    const child = await Window.create({
      title: "Zapp Child Window",
      width: 800,
      height: 600,
    });
    log(`New window: ${child.id}`);
  } catch (e) {
    log(`New window failed: ${e}`);
  }
});

$("btn-new-window-small").addEventListener("click", async () => {
  try {
    const child = await Window.create({
      title: "Notifier",
      width: 400,
      height: 300,
    });
    log(`New small window: ${child.id}`);
  } catch (e) {
    log(`New window failed: ${e}`);
  }
});

// --- Sync (cross-context wait/notify) ---
//
// Sync is a one-shot rendezvous primitive — like a condition variable. The
// payoff is *cross-context*: open a second window with "New Window", click
// "Wait" here, then click "Notify" in the other window. The wait resolves.
//
// (Within a single webview you'd just use a Promise — Sync's value is that
// it works across windows, workers, and the backend through native.)

$("btn-sync-wait").addEventListener("click", async () => {
  $("sync-result").textContent = `Waiting for "demo"...`;
  log(`Sync.wait("demo", 10000) started`);
  const result = await Sync.wait("demo", 10000);
  $("sync-result").textContent = `Result: ${result}`;
  log(`Sync.wait("demo") → ${result}`);
});

$("btn-sync-notify").addEventListener("click", () => {
  Sync.notify("demo");
  $("sync-result").textContent = `Notified "demo" (one)`;
  log(`Sync.notify("demo") — wakes one waiter (FIFO)`);
});

// Open ≥2 windows, click "Wait" in each, then click this in any one of them.
// All waiting windows resolve simultaneously — broadcast.
$("btn-sync-notify-all").addEventListener("click", () => {
  Sync.notifyAll("demo");
  $("sync-result").textContent = `Notified "demo" (all)`;
  log(`Sync.notifyAll("demo") — wakes every waiter`);
});

let guardEnabled = false;
$("btn-guard").addEventListener("click", () => {
  guardEnabled = !guardEnabled;
  win.setCloseGuard(guardEnabled);
  $("btn-guard").textContent = guardEnabled
    ? "Disable Close Guard"
    : "Enable Close Guard";
  log(`Close guard: ${guardEnabled ? "ON" : "OFF"}`);
});

// Close guard handler — prompt user when close is attempted
win.on(WindowEvent.CLOSE, async () => {
  if (guardEnabled) {
    const result = await Dialog.message({
      message: "Are you sure you want to close?",
      buttons: ["Close", "Cancel"],
    });
    if (result.button === 0) {
      log("User confirmed close");
      win.close(); // Force close
    } else {
      log("User cancelled close");
    }
  }
});

// --- Dialogs ---

$("btn-open-file").addEventListener("click", async () => {
  const result = await Dialog.openFile({ title: "Pick a file" });
  if (result.cancelled) {
    $("dialog-result").textContent = "Cancelled";
    log("Open file: cancelled");
  } else {
    $("dialog-result").textContent = result.paths[0];
    log(`Open file: ${result.paths[0]}`);
  }
});

$("btn-save-file").addEventListener("click", async () => {
  const result = await Dialog.saveFile({
    title: "Save as",
    defaultName: "untitled.txt",
  });
  if (result.cancelled) {
    $("dialog-result").textContent = "Cancelled";
  } else {
    $("dialog-result").textContent = result.path;
    log(`Save file: ${result.path}`);
  }
});

$("btn-message").addEventListener("click", async () => {
  const result = await Dialog.message({
    message: "This is a message dialog",
    title: "Hello from Zapp",
    buttons: ["OK", "Cancel", "Maybe"],
  });
  $("dialog-result").textContent = `Button: ${result.button}`;
  log(`Message dialog: button ${result.button}`);
});

// --- Notifications ---

$("btn-notif-perm").addEventListener("click", async () => {
  const status = await Notification.requestPermission();
  $("notif-result").textContent = `Permission: ${status}`;
  log(`Notification permission: ${status}`);
});

let lastNotifId = "";

$("btn-notif-show").addEventListener("click", async () => {
  lastNotifId = await Notification.show({
    id: "demo-notif",
    title: "Zapp Notification",
    body: "Hello from the Zapp framework!",
  });
  $("notif-result").textContent = `Sent: ${lastNotifId}`;
  log(`Notification shown: ${lastNotifId}`);
});

$("btn-notif-actions").addEventListener("click", async () => {
  lastNotifId = await Notification.show({
    title: "New Message",
    body: "You have a new message from Zapp",
    categoryId: "message",
  });
  $("notif-result").textContent = `Sent with actions: ${lastNotifId}`;
  log(`Notification with actions: ${lastNotifId}`);
});

$("btn-notif-update").addEventListener("click", async () => {
  if (!lastNotifId) { log("No notification to update — show one first"); return; }
  await Notification.update(lastNotifId, {
    title: "Updated!",
    body: `Updated at ${new Date().toLocaleTimeString()}`,
  });
  log(`Notification updated: ${lastNotifId}`);
});

$("btn-notif-remove").addEventListener("click", async () => {
  if (!lastNotifId) { log("No notification to remove"); return; }
  await Notification.removeDelivered(lastNotifId);
  $("notif-result").textContent = `Removed: ${lastNotifId}`;
  log(`Notification removed: ${lastNotifId}`);
  lastNotifId = "";
});

// Test attachment — double-click the Show button
$("btn-notif-show").addEventListener("dblclick", async () => {
  // Use a file dialog to pick an image for the attachment
  const result = await Dialog.openFile({ title: "Pick an image for notification" });
  if (result.cancelled || !result.paths?.[0]) return;
  lastNotifId = await Notification.show({
    title: "Rich Notification",
    body: "This one has an image attachment!",
    attachment: result.paths[0],
  });
  log(`Notification with attachment: ${lastNotifId}`);
});

let groupCount = 0;
$("btn-notif-grouped").addEventListener("click", async () => {
  groupCount++;
  const id = await Notification.show({
    title: `Message ${groupCount}`,
    body: "This notification is part of a group",
    threadId: "chat-group",
  });
  log(`Grouped notification #${groupCount}: ${id}`);
});

// --- Workers ---

let myWorker: InstanceType<typeof Worker> | null = null;

$("btn-worker-create").addEventListener("click", () => {
  if (myWorker) {
    log("Worker already running");
    return;
  }
  myWorker = new Worker("./worker.ts");

  // Listen for pong responses on channel
  myWorker.receive("pong", (data) => {
    $("worker-result").textContent = `Pong: ${JSON.stringify(data)}`;
    log(`Worker pong: ${JSON.stringify(data)}`);
  });

  // Listen for service results on channel
  myWorker.receive("service-result", (data) => {
    $("worker-result").textContent = `Service: ${JSON.stringify(data)}`;
    log(`Worker service result: ${JSON.stringify(data)}`);
  });

  // Raw message listener
  myWorker.onmessage = (event) => {
    log(`Worker raw message: ${JSON.stringify(event.data)}`);
  };

  $("worker-result").textContent = "Worker created";
  log("Worker created");
});

$("btn-worker-ping").addEventListener("click", () => {
  if (!myWorker) { log("No worker — create one first"); return; }
  myWorker.send("ping", { message: "hello", time: Date.now() });
  log("Sent ping to worker");
});

$("btn-worker-service").addEventListener("click", () => {
  if (!myWorker) { log("No worker — create one first"); return; }
  myWorker.send("invoke-service", { name: "World" });
  log("Asked worker to invoke greet service");
});

$("btn-worker-terminate").addEventListener("click", () => {
  if (!myWorker) { log("No worker"); return; }
  myWorker.terminate();
  myWorker = null;
  $("worker-result").textContent = "Terminated";
  log("Worker terminated");
});

// --- Dock ---

$("btn-dock-badge").addEventListener("click", () => {
  Dock.setBadge("3");
  log("Dock badge set to 3");
});

$("btn-dock-clear").addEventListener("click", () => {
  Dock.removeBadge();
  log("Dock badge cleared");
});

$("btn-dock-bounce").addEventListener("click", () => {
  log("Dock will bounce in 3s — switch to another app!");
  setTimeout(() => {
    Dock.bounce("critical");
  }, 3000);
});

$("btn-dock-hide").addEventListener("click", () => {
  Dock.hideIcon();
  log("Dock icon hidden");
});

$("btn-dock-show").addEventListener("click", () => {
  Dock.showIcon();
  log("Dock icon shown");
});

// --- Events ---

Events.on("custom:ping", (payload) => {
  $("event-log").textContent = `Received: ${JSON.stringify(payload)}`;
  log(`Event received: custom:ping`);
});

$("btn-emit").addEventListener("click", () => {
  Events.emit("custom:ping", { time: Date.now() });
  log("Emitted custom:ping");
});

// --- Backend state push ---
//
// Backend (src/backend.ts) owns a counter and emits "counter:tick" every 2s
// via Events.emit, which broadcasts to every webview through the native
// dispatchEventToAll bridge. Open multiple windows — they all stay in sync
// without any per-window polling or fetching.

Events.on("counter:tick", (data: any) => {
  $("counter-display").textContent =
    `Counter: ${data.value}  (ts: ${new Date(data.ts).toLocaleTimeString()})`;
});

// --- Window Events ---

win.on(WindowEvent.RESIZE, (p) => {
  log(`Resized: ${p.size?.width}x${p.size?.height}`);
});

win.on(WindowEvent.FOCUS, () => log("Window focused"));
win.on(WindowEvent.BLUR, () => log("Window blurred"));

win.on(WindowEvent.MOVE, (p) => {
  log(`Moved: ${p.position?.x},${p.position?.y}`);
});

// --- Other ---

$("btn-external").addEventListener("click", () => {
  App.openExternal("https://zapp.dev");
  log("Opened zapp.dev in browser");
});

$("btn-ctx-menu").addEventListener("click", (e) => {
  e.preventDefault();
  ContextMenu.show(
    [
      { label: "Copy", action: () => log("Context: Copy") },
      { label: "Paste", action: () => log("Context: Paste") },
      { type: "separator" },
      { label: "Delete", action: () => log("Context: Delete") },
    ],
    { x: e.clientX, y: e.clientY },
  );
});

// --- App Events (frontend) ---

App.on(AppEvent.REOPEN, () => log("App event: reopen (dock icon)"));
App.on(AppEvent.DID_BECOME_ACTIVE, () => log("App event: became active"));
App.on(AppEvent.DID_RESIGN_ACTIVE, () => log("App event: resigned active"));
App.on(AppEvent.OPEN_URL, (data) =>
  log(`App event: deep link ${JSON.stringify(data)}`),
);

Notification.on("response", (r: NotificationResponse) => {
  if (r.actionId === "DEFAULT") {
    log(`Notification clicked: ${r.id}`);
  } else if (r.userText) {
    log(
      `Notification reply: "${r.userText}" (action: ${r.actionId}, id: ${r.id})`,
    );
  } else {
    log(`Notification action: ${r.actionId} on ${r.id}`);
  }
});

log("App initialized");
