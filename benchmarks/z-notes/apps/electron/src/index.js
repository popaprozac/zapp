const { app, BrowserWindow, ipcMain } = require("electron");
const { DatabaseSync } = require("node:sqlite");
const { existsSync, writeFileSync } = require("node:fs");
const path = require("node:path");

const databasePath = "/tmp/z-notes-benchmark-electron.sqlite3";
const benchmarkControlPath = "/tmp/z-notes-benchmark-electron.control";
const benchmarkReadyPath = "/tmp/z-notes-benchmark-electron.ready";
const benchmarkResultPath = "/tmp/z-notes-benchmark-electron.result.json";

function withDatabase(operation) {
  const database = new DatabaseSync(databasePath);
  try {
    database.exec(`
      CREATE TABLE IF NOT EXISTS notes (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL
      );
      INSERT OR IGNORE INTO notes (id, title, body) VALUES
        (1, 'Welcome to Z Notes', 'A native notes application implemented across desktop frameworks.'),
        (2, 'One workload', 'The frontend, storage behavior, and workflow stay equivalent.');
    `);
    return operation(database);
  } finally {
    database.close();
  }
}

function listNotes() {
  return withDatabase((database) => database
    .prepare("SELECT id, title, body FROM notes ORDER BY id")
    .all()
    .map((note) => ({
      id: String(note.id),
      title: note.title,
      body: note.body,
    })));
}

function createNote(input) {
  if (!input || typeof input.title !== "string" || input.title.length === 0) {
    throw new TypeError("a note title is required");
  }
  if (typeof input.body !== "string") {
    throw new TypeError("a note body is required");
  }
  return withDatabase((database) => {
    const next = database
      .prepare("SELECT COALESCE(MAX(id), 0) + 1 AS id FROM notes")
      .get();
    database
      .prepare("INSERT INTO notes (id, title, body) VALUES (?, ?, ?)")
      .run(next.id, input.title, input.body);
    return {
      id: String(next.id),
      title: input.title,
      body: input.body,
    };
  });
}

ipcMain.handle("notes:list", listNotes);
ipcMain.handle("notes:create", (_event, input) => createNote(input));
ipcMain.handle("benchmark:mode", () => existsSync(benchmarkControlPath));
ipcMain.handle("benchmark:report", (_event, report) => {
  const path = report?.phase === "ready"
    ? benchmarkReadyPath
    : benchmarkResultPath;
  writeFileSync(path, typeof report?.payload === "string" ? report.payload : "");
});

function createWindow() {
  const window = new BrowserWindow({
    width: 860,
    height: 600,
    title: "Z Notes Benchmark",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, "preload.js"),
    },
  });
  void window.loadFile(path.join(__dirname, "index.html"));
}

app.whenReady().then(() => {
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => app.quit());
