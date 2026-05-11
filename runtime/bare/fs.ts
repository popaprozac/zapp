// Allowlist-enforcing wrapper around `bare-fs`.
//
// `bare-fs` is the holepunch-maintained Node-shaped filesystem module
// for Bare runtimes. Its calls go through libuv directly — they don't
// flow through Zapp's existing `native/fs/fs.zc` allowlist enforcement
// (which gates the WebView's FS API). Without a wrapper, code in a
// Zapp worker that does `import fs from 'bare-fs'` would have full
// process-level filesystem access regardless of the project's
// `fs.allow` config.
//
// This module re-exports bare-fs's surface with each call gated by a
// prefix-match against an allowlist. The allowlist is sourced from the
// host process — bare workers receive it via
// `globalThis.__zappBridge.fsAllowlist` during the worker bootstrap
// (the Zapp CLI populates it from the project's `fs.allow` config plus
// any runtime grants from the dialog API).
//
// Usage in a Zapp worker:
//
// ```ts
// import * as fs from "@zappdev/runtime/bare/fs";
// await fs.promises.readFile("/path/within/allowlist", "utf8");
// ```
//
// **DO NOT** `import "bare-fs"` directly inside a Zapp worker — that
// bypasses the allowlist.

// Lazy-resolved bare-fs handle. We can't statically `import "bare-fs"`
// because Vite/Rolldown bundles workers and a missing bare-fs would
// fail user builds even when they don't reach for this module. Instead
// we resolve at first call via a runtime-built require expression
// that's invisible to the bundler's static analysis.
let _bareFs: any | null = null;
let _bareFsAttempted = false;
function getBareFs(): any {
  if (_bareFs) return _bareFs;
  if (_bareFsAttempted) return null;
  _bareFsAttempted = true;
  try {
    // Function-constructor escape — same trick worker-globals/_install.ts
    // uses to keep the spec opaque to bundlers. `require` is provided by
    // bare-module in Bare worker contexts; in the webview this falls
    // through to the catch and the wrapper functions throw a clear error.
    const requirer = new Function("s", "return require(s)");
    _bareFs = requirer("bare-fs");
  } catch {
    _bareFs = null;
  }
  return _bareFs;
}

function delegate(method: string, args: unknown[]): any {
  const fs = getBareFs();
  if (!fs) {
    throw new Error(
      "[zapp] bare-fs not installed. Run `bun install bare-fs` in your project."
    );
  }
  return fs[method](...args);
}

export class FsAllowlistError extends Error {
  readonly path: string;
  readonly allowlist: readonly string[];
  constructor(path: string, allowlist: readonly string[]) {
    super(
      `[zapp] filesystem access denied: "${path}" is not under any allowed prefix.\n` +
      (allowlist.length === 0
        ? "  No allowlist configured. Add to zapp.config.ts:\n" +
          "    fs: { allow: [\"~/Library/Application Support/your-app\"] }\n"
        : "  Allowed prefixes:\n" + allowlist.map(p => `    ${p}`).join("\n"))
    );
    this.name = "FsAllowlistError";
    this.path = path;
    this.allowlist = allowlist;
  }
}

// Resolve and check a path against the host-provided allowlist. The
// allowlist is a list of fully-resolved prefixes the host has cleared
// for the worker to access. We do a simple prefix match — no symlink
// following. (Symlink-walking belongs in the native fs.zc layer; the
// native side always has authoritative process-level enforcement
// underneath us.)
function checkAllowed(p: string): void {
  const bridge = (globalThis as any).__zappBridge;
  const allowlist: string[] = (bridge && bridge.fsAllowlist) ?? [];
  for (const prefix of allowlist) {
    if (p === prefix || p.startsWith(prefix + "/")) return;
  }
  throw new FsAllowlistError(p, allowlist);
}

type PathArg = string | URL | { toString(): string };
function asString(p: PathArg): string {
  if (typeof p === "string") return p;
  if (p instanceof URL) return p.pathname;
  return p.toString();
}

// --- Sync APIs ---------------------------------------------------------

export const readFileSync   = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("readFileSync",   [p, ...rest]));
export const writeFileSync  = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("writeFileSync",  [p, ...rest]));
export const appendFileSync = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("appendFileSync", [p, ...rest]));
export const existsSync     = (p: PathArg)                 => (checkAllowed(asString(p)), delegate("existsSync",     [p]));
export const statSync       = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("statSync",       [p, ...rest]));
export const lstatSync      = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("lstatSync",      [p, ...rest]));
export const mkdirSync      = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("mkdirSync",      [p, ...rest]));
export const rmdirSync      = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("rmdirSync",      [p, ...rest]));
export const rmSync         = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("rmSync",         [p, ...rest]));
export const unlinkSync     = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("unlinkSync",     [p, ...rest]));
export const readdirSync    = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("readdirSync",    [p, ...rest]));
export const renameSync     = (from: PathArg, to: PathArg, ...rest: any[]) =>
  (checkAllowed(asString(from)), checkAllowed(asString(to)), delegate("renameSync", [from, to, ...rest]));
export const copyFileSync   = (from: PathArg, to: PathArg, ...rest: any[]) =>
  (checkAllowed(asString(from)), checkAllowed(asString(to)), delegate("copyFileSync", [from, to, ...rest]));

// --- Async (callback) APIs --------------------------------------------

export const readFile  = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("readFile",  [p, ...rest]));
export const writeFile = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("writeFile", [p, ...rest]));
export const stat      = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("stat",      [p, ...rest]));
export const readdir   = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("readdir",   [p, ...rest]));
export const mkdir     = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("mkdir",     [p, ...rest]));
export const unlink    = (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), delegate("unlink",    [p, ...rest]));
export const rename    = (from: PathArg, to: PathArg, ...rest: any[]) =>
  (checkAllowed(asString(from)), checkAllowed(asString(to)), delegate("rename", [from, to, ...rest]));

// --- Promise APIs (fs.promises) ---------------------------------------
// Each method delegates to bareFs.promises.* after the path check passes.
// We construct it lazily so getBareFs is called at most once per process.

let _promises: any;
function getPromises(): any {
  if (_promises) return _promises;
  const fs = getBareFs();
  if (!fs?.promises) {
    throw new Error("[zapp] bare-fs/promises not available. Run `bun install bare-fs`.");
  }
  _promises = fs.promises;
  return _promises;
}

export const promises = {
  readFile:    async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().readFile(p, ...rest)),
  writeFile:   async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().writeFile(p, ...rest)),
  appendFile:  async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().appendFile(p, ...rest)),
  stat:        async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().stat(p, ...rest)),
  lstat:       async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().lstat(p, ...rest)),
  readdir:     async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().readdir(p, ...rest)),
  mkdir:       async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().mkdir(p, ...rest)),
  rm:          async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().rm(p, ...rest)),
  rmdir:       async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().rmdir(p, ...rest)),
  unlink:      async (p: PathArg, ...rest: any[]) => (checkAllowed(asString(p)), getPromises().unlink(p, ...rest)),
  rename:      async (from: PathArg, to: PathArg, ...rest: any[]) =>
    (checkAllowed(asString(from)), checkAllowed(asString(to)), getPromises().rename(from, to, ...rest)),
  copyFile:    async (from: PathArg, to: PathArg, ...rest: any[]) =>
    (checkAllowed(asString(from)), checkAllowed(asString(to)), getPromises().copyFile(from, to, ...rest)),
};

export default {
  readFile, readFileSync, writeFile, writeFileSync, appendFileSync,
  stat, statSync, lstatSync, mkdir, mkdirSync,
  readdir, readdirSync, unlink, unlinkSync,
  rename, renameSync, copyFileSync, rmdirSync, rmSync, existsSync,
  promises,
};
