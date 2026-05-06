import "./style.css";

// Vibrancy demo: when this window was opened with either
// `?vibrancy=...` or `#vibrancy=...`, add a class on <html> so
// style.css can drop the body background and let the
// NSVisualEffectView blur show through. Both are accepted — the
// framework supports query and fragment equally; pick whichever
// fits your routing. Set BEFORE any other code runs so the class
// lands before first paint.
if (location.search.includes("vibrancy=") || location.hash.includes("vibrancy=")) {
  document.documentElement.classList.add("vibrancy-demo");
}
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
  type NotificationResponse,
  Worker,
  Workers,
  Dock,
  Tray,
  type TrayHandle,
  Clipboard,
  Shortcuts,
  Sync,
} from "@zappdev/runtime";
import { greet } from "./zapp";

// --- Setup ---

const win = Window.current();

const result = await greet({ name: "World" });
log(`greet({ name: "World" }) → ${result}`);

// --- Menu ---

let isFullscreen = false;
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
        action: () => {
          isFullscreen = !isFullscreen;
          win.setFullscreen(isFullscreen);
          log(`Fullscreen: ${isFullscreen ? "ON" : "OFF"}`);
        },
      },
    ],
  },
  // Standard Window menu — gives Cmd+W (close), Cmd+M (minimize), and
  // the running-windows submenu macOS users expect.
  { role: "windowMenu", label: "Window" },
]);

// --- UI ---

document.querySelector<HTMLDivElement>("#app")!.innerHTML = `
  <div class="container">
    <h1>Zapp v2</h1>
    <p class="subtitle">Desktop framework — single-binary, no Electron</p>

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
        <button id="btn-always-on-top">Toggle Always-On-Top</button>
        <button id="btn-guard">Enable Close Guard</button>
        <button id="btn-new-window">New Window</button>
        <button id="btn-new-window-small">New Window (small)</button>
        <button id="btn-new-window-vibrant">New Window (vibrancy: sidebar)</button>
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
        <button id="btn-reveal-file">Reveal Last in Finder</button>
        <button id="btn-open-path">Open Last with Default App</button>
        <div id="dialog-result" class="result"></div>
      </section>

      <section>
        <h2>Notifications</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          Double-click <strong>Show</strong> to attach an image.
        </p>
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
        <button id="btn-worker-terminate-by-id">Workers.terminate("h-supervised")</button>
        <div id="worker-result" class="result"></div>
      </section>

      <section>
        <h2>Worker Channels (G7)</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          <code>Workers.postMessage(id, data)</code> /
          <code>Workers.send(id, channel, data)</code> — point-to-point.
          Skips Events.emit's broadcast fan-out.
        </p>
        <button id="btn-channel-direct">Webview → ticker (direct)</button>
        <button id="btn-channel-pipeline">Pipeline: webview → supervised → ticker → supervised</button>
        <div id="channel-result" class="result"></div>
      </section>

      <section>
        <h2>Supervisor (headless: supervised)</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          Restart policy: 2 retries / 30s. Click "Force crash" up to 3 times —
          the 3rd should fire <code>worker:gave-up</code>.
        </p>
        <button id="btn-supervisor-crash">Force crash</button>
        <div id="supervisor-result" class="result"></div>
      </section>

      <section>
        <h2>Clipboard</h2>
        <button id="btn-clip-write-text">Write text</button>
        <button id="btn-clip-read-text">Read text</button>
        <button id="btn-clip-has-image">Has image?</button>
        <button id="btn-clip-read-image">Read image (PNG bytes)</button>
        <button id="btn-clip-clear">Clear</button>
        <div id="clip-result" class="result"></div>
      </section>

      <section>
        <h2>Global Shortcuts</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          Registers <code>CmdOrCtrl+Shift+Z</code>. Switch to another app and
          press it — fires the handler regardless of focus.
        </p>
        <button id="btn-shortcut-register">Register</button>
        <button id="btn-shortcut-unregister">Unregister</button>
        <button id="btn-shortcut-is-registered">Is registered?</button>
        <div id="shortcut-result" class="result"></div>
      </section>

      <section>
        <h2>Theme</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          Toggle macOS appearance (System Settings → Appearance) to see the
          theme-changed event fire live.
        </p>
        <button id="btn-theme-get">Get current theme</button>
        <div id="theme-result" class="result">Theme: ${App.getTheme()}</div>
      </section>

      <section>
        <h2>Dock</h2>
        <button id="btn-dock-badge">Badge "3"</button>
        <button id="btn-dock-clear">Clear Badge</button>
        <button id="btn-dock-bounce">Bounce (in 3s)</button>
        <button id="btn-dock-hide">Hide Icon</button>
        <button id="btn-dock-show">Show Icon</button>
      </section>

      <section>
        <h2>Tray (menu bar)</h2>
        <button id="btn-tray-menu">Create tray w/ menu</button>
        <button id="btn-tray-click">Create click-only tray</button>
        <button id="btn-tray-set-title">Set title "5"</button>
        <button id="btn-tray-clear-title">Clear title</button>
        <button id="btn-tray-set-tooltip">Set tooltip</button>
        <button id="btn-tray-swap-menu">Swap menu</button>
        <button id="btn-tray-attach">Attach popover window</button>
        <button id="btn-tray-detach">Detach window</button>
        <button id="btn-tray-destroy">Destroy</button>
        <div id="tray-result" class="result"></div>
      </section>

      <section>
        <h2>Events</h2>
        <button id="btn-emit">Emit Custom Event</button>
        <div id="event-log" class="result"></div>
      </section>

      <section>
        <h2>Cross-Context State (headless: ticker)</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          A headless worker (<code>src/workers/ticker.ts</code>) emits
          <code>counter:tick</code> every 2s. Open multiple windows —
          they all update in lockstep from one source of truth, no polling.
        </p>
        <div id="counter-display" class="result">Counter: (waiting…)</div>
      </section>

      <section>
        <h2>File Drop (G10)</h2>
        <p style="font-size: 12px; opacity: 0.7; margin: 0 0 8px 0;">
          Drag a file from Finder anywhere into this window. Three
          events fire on the receiving window only:
          <code>file-drop-enter</code>, <code>file-drop-leave</code>,
          <code>file-drop</code> — paths come through as absolute
          strings (DOM <code>File</code> objects don't expose paths).
        </p>
        <div id="drop-zone" class="result" style="min-height: 60px; border: 2px dashed currentColor; padding: 16px; text-align: center; transition: background-color 0.15s;">
          Drop files here (or anywhere in the window)
        </div>
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

let alwaysOnTop = false;
$("btn-always-on-top").addEventListener("click", () => {
  alwaysOnTop = !alwaysOnTop;
  win.setAlwaysOnTop(alwaysOnTop);
  log(`Always-on-top: ${alwaysOnTop ? "ON" : "OFF"}`);
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

$("btn-new-window-vibrant").addEventListener("click", async () => {
  try {
    const child = await Window.create({
      title: "Vibrancy demo (sidebar material)",
      width: 480,
      height: 360,
      vibrancy: "sidebar",
      titleBarStyle: "hiddenInset",
      // Relative URL — resolves against whatever the app's
      // configured initial URL is (Vite dev server in dev, the
      // built zapp:// in prod), so this works in both modes.
      // Hardcoding `zapp://index.html?vibrancy=...` would break in
      // dev because that bypasses the Vite dev server entirely.
      // The new window's main.ts reads `vibrancy=` from either
      // location.search or location.hash; ?query is the user's
      // preferred convention here.
      url: "?vibrancy=sidebar",
    });
    log(`New vibrant window: ${child.id}`);
  } catch (e) {
    log(`New vibrant window failed: ${e}`);
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

let lastPickedPath = "";

$("btn-open-file").addEventListener("click", async () => {
  const result = await Dialog.openFile({ title: "Pick a file" });
  if (result.cancelled) {
    $("dialog-result").textContent = "Cancelled";
    log("Open file: cancelled");
  } else {
    lastPickedPath = result.paths[0];
    $("dialog-result").textContent = lastPickedPath;
    log(`Open file: ${lastPickedPath}`);
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
    lastPickedPath = result.path;
    $("dialog-result").textContent = lastPickedPath;
    log(`Save file: ${lastPickedPath}`);
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

$("btn-reveal-file").addEventListener("click", () => {
  if (!lastPickedPath) { log("Pick a file first"); return; }
  App.showItemInFolder(lastPickedPath);
  log(`Revealed in Finder: ${lastPickedPath}`);
});

$("btn-open-path").addEventListener("click", () => {
  if (!lastPickedPath) { log("Pick a file first"); return; }
  App.openPath(lastPickedPath);
  log(`Opened with default app: ${lastPickedPath}`);
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

// Test attachment — double-click the Show button.
$("btn-notif-show").addEventListener("dblclick", async () => {
  // Use a file dialog to pick an image for the attachment.
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

// Demonstrates `Workers.terminate(id)` — kill any worker (headless or
// dedicated) by its id without holding the Worker instance.
$("btn-worker-terminate-by-id").addEventListener("click", () => {
  Workers.terminate("h-supervised");
  log(`Workers.terminate("h-supervised") — supervised headless worker killed`);
});

// --- Supervisor (G6) ---

Events.on("worker:crashed", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  $("supervisor-result").textContent = `crashed: ${d.id} — ${d.message}`;
  log(`worker:crashed ${d.id}: ${d.message}`);
});
Events.on("worker:restarted", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  $("supervisor-result").textContent = `restarted: ${d.id}`;
  log(`worker:restarted ${d.id}`);
});
Events.on("worker:gave-up", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  $("supervisor-result").textContent = `gave up: ${d.id}`;
  log(`worker:gave-up ${d.id}`);
});

$("btn-supervisor-crash").addEventListener("click", () => {
  Events.emit("force-crash", {});
  log("emitted force-crash to supervised worker");
});

// --- Worker channels (G7) ---

// Webview → ticker direct: ticker has receive("ping") that broadcasts
// via Events when no replyTo is set, so we listen for ticker:pong here.
Events.on("ticker:pong", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  $("channel-result").textContent = `direct: ${JSON.stringify(d)}`;
  log(`Workers.send → ticker → Events.emit pong: ${JSON.stringify(d)}`);
});

$("btn-channel-direct").addEventListener("click", () => {
  Workers.postMessage("h-ticker", { __zc: "ping", d: { from: "webview", ts: Date.now() } });
  log(`Workers.postMessage("h-ticker", ping) — direct webview→worker`);
});

// Pipeline: webview emits force-pipeline → supervised → Workers.send →
// ticker → Workers.send pong → supervised → Events.emit pipeline-done.
Events.on("supervised:pipeline-done", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  $("channel-result").textContent = `pipeline: ${d.hop}`;
  log(`pipeline complete: ${d.hop}`);
});

$("btn-channel-pipeline").addEventListener("click", () => {
  Events.emit("relay-to-ticker", {});
  log(`emitted relay-to-ticker — supervised will Workers.send to ticker`);
});

// --- Clipboard ---

$("btn-clip-write-text").addEventListener("click", async () => {
  const text = `Hello from Zapp at ${new Date().toLocaleTimeString()}`;
  await Clipboard.writeText(text);
  $("clip-result").textContent = `Wrote: ${text}`;
  log(`Clipboard write: "${text}"`);
});

$("btn-clip-read-text").addEventListener("click", async () => {
  const text = await Clipboard.readText();
  $("clip-result").textContent = `Read: ${text || "(empty)"}`;
  log(`Clipboard read: "${text}"`);
});

$("btn-clip-has-image").addEventListener("click", async () => {
  const has = await Clipboard.has("image");
  $("clip-result").textContent = `has("image"): ${has}`;
  log(`Clipboard has image: ${has}`);
});

$("btn-clip-read-image").addEventListener("click", async () => {
  const bytes = await Clipboard.readImage();
  if (!bytes) {
    $("clip-result").textContent = "No image on clipboard";
    log(`Clipboard image: (none — copy an image somewhere first)`);
    return;
  }
  $("clip-result").textContent = `Got ${bytes.length}-byte PNG`;
  log(`Clipboard image: ${bytes.length} bytes`);
});

$("btn-clip-clear").addEventListener("click", async () => {
  await Clipboard.clear();
  $("clip-result").textContent = "(cleared)";
  log(`Clipboard cleared`);
});

// --- Global Shortcuts ---

const SHORTCUT = "CmdOrCtrl+Shift+Z";

$("btn-shortcut-register").addEventListener("click", async () => {
  const ok = await Shortcuts.register(SHORTCUT, () => {
    log(`Global shortcut fired: ${SHORTCUT}`);
    $("shortcut-result").textContent = `Last fired: ${new Date().toLocaleTimeString()}`;
    win.show();  // bring the app forward when the shortcut fires
  });
  $("shortcut-result").textContent = ok
    ? `Registered ${SHORTCUT} — try it from any app`
    : `Failed to register (already in use?)`;
  log(`Shortcuts.register(${SHORTCUT}) → ${ok}`);
});

$("btn-shortcut-unregister").addEventListener("click", async () => {
  await Shortcuts.unregister(SHORTCUT);
  $("shortcut-result").textContent = `Unregistered ${SHORTCUT}`;
  log(`Shortcuts.unregister(${SHORTCUT})`);
});

$("btn-shortcut-is-registered").addEventListener("click", async () => {
  const reg = await Shortcuts.isRegistered(SHORTCUT);
  $("shortcut-result").textContent = `isRegistered: ${reg}`;
  log(`Shortcuts.isRegistered(${SHORTCUT}) → ${reg}`);
});

// --- Theme ---

$("btn-theme-get").addEventListener("click", () => {
  const theme = App.getTheme();
  $("theme-result").textContent = `Theme: ${theme}`;
  log(`App.getTheme() → ${theme}`);
});

App.on(AppEvent.THEME_CHANGED, (data: any) => {
  const theme = data?.theme ?? App.getTheme();
  $("theme-result").textContent = `Theme: ${theme} (just changed)`;
  log(`app:theme-changed → ${theme}`);
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

// --- Tray ---
//
// Look at the top-right of your menu bar after clicking "Create tray".
// The icon dispatches click/right-click events when no menu is set;
// when a menu is set the system shows it on click and we never see the
// click itself. Path is absolute for testing — for a real app, ship the
// PNG inside `build/` and load it via a relative path or bundle helper.
//
// IMPORTANT: every Window has its own WKWebView and its own JS context.
// `activeTray` and `attachedWin` are per-window — clicking detach /
// destroy from inside the popover won't find a tray. Drive tray buttons
// from the main window; the popover is for verifying show/hide/dismiss.

const TRAY_ICON = "/Users/zach/code/zapp/hello-world/build/tray-icon.png";
let activeTray: TrayHandle | null = null;
let attachedWin: Awaited<ReturnType<typeof Window.create>> | null = null;

$("btn-tray-menu").addEventListener("click", () => {
  if (activeTray) { log("Tray already exists — destroy it first"); return; }
  activeTray = Tray.create({
    icon: TRAY_ICON,
    tooltip: "Zapp Hello-World",
    menu: [
      { label: "Open Hello-World", action: () => { win.show(); log("Tray menu: open"); } },
      { type: "separator" },
      { label: "Ping log", action: () => log("Tray menu: ping") },
      { type: "separator" },
      { label: "Quit", role: "quit" },
    ],
  });
  $("tray-result").textContent = `Tray ${activeTray.id} (with menu)`;
  log(`Tray created with menu: id=${activeTray.id}`);
});

$("btn-tray-click").addEventListener("click", () => {
  if (activeTray) { log("Tray already exists — destroy it first"); return; }
  activeTray = Tray.create({
    icon: TRAY_ICON,
    tooltip: "Click-only tray",
  });
  activeTray.on("click", () => log(`Tray ${activeTray!.id}: left-click`));
  activeTray.on("right-click", () => log(`Tray ${activeTray!.id}: right-click`));
  $("tray-result").textContent = `Tray ${activeTray.id} (click-only)`;
  log(`Tray created click-only: id=${activeTray.id}`);
});

$("btn-tray-set-title").addEventListener("click", () => {
  if (!activeTray) { log("No tray"); return; }
  activeTray.setTitle("5");
  log(`Tray title → "5"`);
});

$("btn-tray-clear-title").addEventListener("click", () => {
  if (!activeTray) { log("No tray"); return; }
  activeTray.setTitle("");
  log(`Tray title cleared`);
});

$("btn-tray-set-tooltip").addEventListener("click", () => {
  if (!activeTray) { log("No tray"); return; }
  activeTray.setTooltip(`Updated at ${new Date().toLocaleTimeString()}`);
  log(`Tray tooltip updated`);
});

$("btn-tray-swap-menu").addEventListener("click", () => {
  if (!activeTray) { log("No tray"); return; }
  activeTray.setMenu([
    { label: "Swapped at " + new Date().toLocaleTimeString(), enabled: false },
    { type: "separator" },
    { label: "New action", action: () => log("Tray menu: new action fired") },
    { label: "Quit", role: "quit" },
  ]);
  log(`Tray menu swapped`);
});

$("btn-tray-attach").addEventListener("click", async () => {
  if (!activeTray) { log("Create a tray first"); return; }
  if (!attachedWin) {
    attachedWin = await Window.create({
      title: "Tray Popover",
      width: 320,
      height: 480,
      borderless: true,
      visible: false,    // hide until attach toggles it on
      resizable: false,
    });
    log(`Created popover window ${attachedWin.id}`);
  }
  activeTray.attachWindow(attachedWin, {
    position: "centerBelow",
    dismissOnBlur: true,
    toggleOnClick: true,
  });
  log(`Tray ${activeTray.id} ↦ window ${attachedWin.id} (left-click to toggle, right-click for menu if set)`);
});

$("btn-tray-detach").addEventListener("click", () => {
  if (!activeTray) { log("No tray"); return; }
  activeTray.detachWindow();
  log(`Tray ${activeTray.id} window detached`);
});

$("btn-tray-destroy").addEventListener("click", () => {
  if (!activeTray) { log("No tray"); return; }
  activeTray.destroy();
  log(`Tray ${activeTray.id} destroyed`);
  activeTray = null;
  // Drop the popover reference too — destroying the tray ordered out
  // its attached window; recreating the tray + reusing the same
  // popover handle would race against the orderOut.
  attachedWin = null;
  $("tray-result").textContent = "";
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

// --- Cross-context state push ---
//
// The `ticker` headless worker (configured in zapp.config.ts → headless,
// source at src/workers/ticker.ts) emits `counter:tick` every 2s via
// Events.emit. The native bridge fans that out to every webview, so
// every open window stays in sync from one authoritative source —
// no per-window polling.
//
// (Previously this was driven by `src/backend.ts`. The --backend flag
// is currently stale — see project_backend_stale memory — so headless
// workers are the supported way to do app-wide background work.)

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

// --- File drop (G10) ---
//
// Three-layer feedback:
//  - Window-level "drag is in flight" — file-drop-enter / leave.
//    Tells the app a file drag is happening at all.
//  - Element-level "cursor is over the drop target" — hit-test the
//    drop-zone rect against `file-drop-over` coordinates. Lets us
//    style the zone differently when it's about to receive vs when
//    the drag is just hovering somewhere else in the window.
//  - The drop itself — file-drop with the final paths.
//
// We track these as separate UI states so the user can see a soft
// "drag in flight" cue across the whole window, plus a brighter
// "ready to drop" cue only when their cursor is on the target.

let dragInFlight = false;
let overTarget = false;

function paintDropZone() {
  const dz = $("drop-zone");
  if (overTarget) {
    dz.style.backgroundColor = "rgba(0, 122, 255, 0.30)";
    dz.style.borderStyle = "solid";
  } else if (dragInFlight) {
    dz.style.backgroundColor = "rgba(0, 122, 255, 0.10)";
    dz.style.borderStyle = "dashed";
  } else {
    dz.style.backgroundColor = "";
    dz.style.borderStyle = "dashed";
  }
}

function isOverDropZone(x: number, y: number): boolean {
  const r = $("drop-zone").getBoundingClientRect();
  return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
}

Events.on("file-drop-enter", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  const paths: string[] = d.paths ?? [];
  dragInFlight = true;
  overTarget = isOverDropZone(d.x, d.y);
  $("drop-zone").textContent = `Dragging ${paths.length} file(s)…`;
  paintDropZone();
});

Events.on("file-drop-over", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  const wasOver = overTarget;
  overTarget = isOverDropZone(d.x, d.y);
  if (wasOver !== overTarget) paintDropZone();
});

Events.on("file-drop-leave", () => {
  dragInFlight = false;
  overTarget = false;
  $("drop-zone").textContent = "Drop files here (or anywhere in the window)";
  paintDropZone();
});

Events.on("file-drop", (data: any) => {
  const d = typeof data === "string" ? JSON.parse(data) : data;
  const paths: string[] = d.paths ?? [];
  const summary = paths.length === 1 ? paths[0] : `${paths.length} files`;
  dragInFlight = false;
  overTarget = false;
  $("drop-zone").textContent = `Dropped ${summary} at (${d.x}, ${d.y})`;
  paintDropZone();
  log(`file-drop: ${summary} at (${d.x}, ${d.y})`);
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
//
// STARTED fires once at app boot, *before* this script runs in any
// webview, so listening here only catches it on subsequent webviews
// (e.g. a new window opening). SHUTDOWN fires when the user quits;
// the webview is mid-teardown when it dispatches.

App.on(AppEvent.STARTED, () => log("App event: started"));
App.on(AppEvent.SHUTDOWN, () => log("App event: shutdown"));
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
