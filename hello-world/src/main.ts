import type { NotificationResponse } from "../../runtime/notification";
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
} from "@zappdev/runtime";

// --- Setup ---

const win = Window.current();

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
            log(`Opened: ${result.paths[0]}`);
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
        <button id="btn-notif-show">Show Notification</button>
        <button id="btn-notif-actions">With Actions</button>
        <div id="notif-result" class="result"></div>
      </section>

      <section>
        <h2>Events</h2>
        <button id="btn-emit">Emit Custom Event</button>
        <div id="event-log" class="result"></div>
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
  const el = document.getElementById("log")!;
  const line = document.createElement("div");
  line.textContent = `[${new Date().toLocaleTimeString()}] ${msg}`;
  el.prepend(line);
  // Keep last 20 lines
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

$("btn-notif-show").addEventListener("click", async () => {
  const id = await Notification.show({
    title: "Zapp Notification",
    body: "Hello from the Zapp framework!",
  });
  $("notif-result").textContent = `Sent: ${id}`;
  log(`Notification shown: ${id}`);
});

$("btn-notif-actions").addEventListener("click", async () => {
  const id = await Notification.show({
    title: "New Message",
    body: "You have a new message from Zapp",
    categoryId: "message",
  });
  $("notif-result").textContent = `Sent with actions: ${id}`;
  log(`Notification with actions: ${id}`);
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

// --- Window Events ---

win.on(WindowEvent.RESIZE, (p) => {
  log(`Resized: ${p.size?.width}x${p.size?.height}`);
});

win.on(WindowEvent.FOCUS, () => log("Window focused"));
win.on(WindowEvent.BLUR, () => log("Window blurred"));

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
