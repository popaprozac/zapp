import { rm } from "node:fs/promises";

const databases = [
  "/tmp/z-notes-benchmark-zapp.sqlite3",
  "/tmp/z-notes-benchmark-electron.sqlite3",
  "/tmp/z-notes-benchmark-electrobun.sqlite3",
  "/tmp/z-notes-benchmark-tauri.sqlite3",
  "/tmp/z-notes-benchmark-wails.sqlite3",
];

await Promise.all(databases.map((database) => rm(database, { force: true })));
console.log(`reset ${databases.length} Z Notes benchmark databases`);
