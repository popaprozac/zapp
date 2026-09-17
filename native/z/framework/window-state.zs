import json from "std/json";
import fs from "std/fs";
import console from "std/console";
import { sleep } from "std/time";
import { Mutex } from "std/sync";
import { replace } from "std/memory";
import { SyncSender, SyncReceiver } from "std/channel";
import { thread } from "std/thread";
import { Bounds } from "./window-display.zs";
import { WindowPosition } from "./window-positioning.zs";

// Versioned framework data, not configuration or a document/session database.
internal struct SavedWindowState {
  key: String;
  width: u32;
  height: u32;
  x: f64;
  y: f64;
  maximized: boolean;
}

internal struct WindowStateFile {
  version: u32;
  windows: Array<SavedWindowState>;
}

internal function validSavedWindowState(in state: SavedWindowState): boolean {
  // Bound hostile/corrupt coordinates before passing them to a native toolkit.
  return state.key.byteLength > 0 && state.key.byteLength <= 256
    && state.width > 0 && state.height > 0 && state.width <= 100000 && state.height <= 100000
    && state.x >= -1000000 && state.x <= 1000000 && state.y >= -1000000 && state.y <= 1000000;
}

internal function decodeWindowStates(in source: String): Array<SavedWindowState> {
  if (source.byteLength > 1048576) return Array<SavedWindowState>();
  const decoded = attempt json.decode<WindowStateFile>(in source);
  let result = Array<SavedWindowState>();
  match (decoded) {
    success(file) => {
      if (file.version != 1 || file.windows.length > 1024) return result;
      for (const item of file.windows) {
        if (!validSavedWindowState(in item)) return Array<SavedWindowState>();
        for (const previous of result) {
          if (previous.key == item.key) return Array<SavedWindowState>();
        }
        result.push(copy item);
      }
    }
    failure(_) => {}
  }
  return result;
}

internal function loadWindowStates(in path: String): Array<SavedWindowState> {
  if (!fs.exists(path)) return Array<SavedWindowState>();
  return match (attempt fs.readText(path)) {
    success(source) => decodeWindowStates(in source);
    failure(message) => {
      console.log(`Zapp window state could not be read: ${message}`);
      select Array<SavedWindowState>();
    }
  };
}

internal function putWindowState(inout states: Array<SavedWindowState>, in value: SavedWindowState): void {
  let index: usize = 0;
  while (index < states.length) {
    if (states[index].key == value.key) { states[index] = copy value; return; }
    index = index + 1;
  }
  // A bound on framework-owned storage, not a growing history of closed windows.
  if (states.length < 1024) states.push(copy value);
}

// Keep the titlebar and as much of an oversized window as possible accessible.
internal function recoveredWindowPosition(position: WindowPosition, frameWidth: f64,
  frameHeight: f64, workArea: Bounds): WindowPosition {
  const maxX = workArea.x + (workArea.width > frameWidth ? workArea.width - frameWidth : f64(0));
  const maxY = workArea.y + (workArea.height > frameHeight ? workArea.height - frameHeight : f64(0));
  return WindowPosition({
    x: position.x < workArea.x ? workArea.x : position.x > maxX ? maxX : position.x,
    y: position.y < workArea.y ? workArea.y : position.y > maxY ? maxY : position.y,
  });
}

internal struct WindowStateMailbox {
  pending: Array<SavedWindowState> = Array<SavedWindowState>();
  queued: boolean = false;
  stopping: boolean = false;
}

internal struct WindowStateBatch {
  states: Array<SavedWindowState>;
  stopping: boolean;
}

internal readonly class WindowStateInbox {
  private readonly state: Mutex<WindowStateMailbox>;
  constructor() { this.state = Mutex(WindowStateMailbox()); }

  function stop(): boolean {
    return this.state.withLock((inout state): boolean => {
      if (state.stopping) return false;
      state.stopping = true;
      if (state.queued) return false;
      state.queued = true;
      return true;
    });
  }

  function remember(in value: SavedWindowState): boolean {
    return this.state.withLock((inout state): boolean => {
      if (state.stopping) return false;
      putWindowState(inout state.pending, in value);
      if (state.queued) return false;
      state.queued = true;
      return true;
    });
  }

  function take(): WindowStateBatch {
    return this.state.withLock((inout state): WindowStateBatch => {
      let empty = Array<SavedWindowState>();
      const states = replace(inout state.pending, move empty);
      state.queued = false;
      return WindowStateBatch({ states, stopping: state.stopping });
    });
  }

  function pendingCount(): usize { return this.state.withLock((in state): usize => state.pending.length); }
}

function saveWindowStateBatch(in directory: String, in pending: Array<SavedWindowState>): void throws String {
  try fs.createDirectories(directory);
  const path = `${directory}/window-state.json`;
  const lock = try fs.lock(`${directory}/window-state.lock`);
  let merged = loadWindowStates(in path);
  for (const value of pending) { putWindowState(inout merged, in value); }
  const file = WindowStateFile({ version: 1, windows: move merged });
  const source = match (attempt json.encode(in file)) {
    success(value) => value;
    failure(_) => throw "window state contains unencodable geometry";
  };
  const temporary = `${directory}/window-state.pending`;
  try fs.writeText(temporary, source);
  try fs.replace(temporary, path);
}

internal function writeWindowStates(directory: String, inbox: WindowStateInbox,
  receiver: SyncReceiver<boolean>): void {
  while (true) {
    match (receiver.receive()) { some(_) => {} none => return; }
    // No polling while idle. Coalesce a burst, then encode/write off the UI thread.
    sleep(200);
    const batch = inbox.take();
    if (batch.states.length > 0) {
      match (attempt saveWindowStateBatch(in directory, in batch.states)) {
        success => {}
        failure(message) => console.log(`Zapp window state could not be saved: ${message}`);
      }
    }
    if (batch.stopping) return;
  }
}

internal class WindowStateStore on thread.main {
  readonly directory: String;
  readonly inbox: WindowStateInbox;
  readonly sender: SyncSender<boolean>;
  loaded: boolean;
  states: Array<SavedWindowState>;

  constructor(directory: String, inbox: WindowStateInbox, sender: SyncSender<boolean>) {
    this.directory = move directory;
    this.inbox = inbox;
    this.sender = sender;
    this.loaded = false;
    this.states = Array<SavedWindowState>();
  }

  function stop(): void {
    if (this.inbox.stop()) { const sent = attempt this.sender.send(true); }
  }

  function find(inout this, in key: String): Option<SavedWindowState> {
    if (!this.loaded) {
      const path = `${this.directory}/window-state.json`;
      this.states = loadWindowStates(in path);
      this.loaded = true;
    }
    for (const value of this.states) { if (value.key == key) return Option.some(copy value); }
    return Option.none;
  }

  function remember(inout this, value: SavedWindowState): void {
    if (!validSavedWindowState(in value)) return;
    let found = false;
    let index: usize = 0;
    while (index < this.states.length) {
      if (this.states[index].key == value.key) { this.states[index] = copy value; found = true; break; }
      index = index + 1;
    }
    if (!found && this.states.length < 1024) this.states.push(copy value);
    const wake = this.inbox.remember(in value);
    // Exactly one token can be outstanding: queued stays true until the sole
    // receiver has consumed it AND taken the batch. Capacity is one, so this
    // synchronous send cannot wait for capacity. No filesystem work holds the lock.
    if (wake) { const sent = attempt this.sender.send(true); }
  }
}
