# Writing Native Services in Zen-C

A **service** is a Zen-C function that your JavaScript code can invoke.
Services are the primary bridge from the UI to privileged native
operations — file I/O, system APIs, external processes, anything that
shouldn't or can't run in JS.

## The minimal service

```zc
// zapp/app.zc
import "app/app.zc";

fn greet(_app: App*, _args: JsonValue*) -> string {
    return "Hello from native!";
}

fn run_app() -> int {
    let config = AppConfig{
        name: "my-app",
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: Zapp::inspectable_auto(),
        maxWorkers: 0,
        qjsStackSize: 0,
    };
    let app = App::new(config);

    // Register the service — must happen before app.run()
    app.service.add("greet", greet);

    let opts = WindowOptions::create("my-app");
    opts.visible = false;
    let win = app.window.create(&opts);
    win.on_ready(fn (_id: int, _handle: void*) -> void {
        Window{id: _id, handle: _handle}.show();
    });

    return app.run();
}
```

From JS:
```ts
import { Services } from "@zappdev/runtime";

const result = await Services.invoke<string>("greet");
console.log(result); // "Hello from native!"
```

## The handler signature

Every service handler has this exact shape:

```zc
fn handler_name(app: App*, args: JsonValue*) -> string
```

| Param | Type | Meaning |
|---|---|---|
| `app` | `App*` | The live app pointer. Use for cross-service calls / state access. Often unused — prefix with `_` to silence warning. |
| `args` | `JsonValue*` | Arguments from JS. Can be `NULL` if caller passed no args. |
| return | `string` | JSON-encoded response string. Empty string for "no response payload". |

**Always take `JsonValue*`**, not a concrete Zen-C struct. Zapp doesn't
auto-deserialize into typed structs — you walk the `JsonValue` tree and
pull out what you need.

## Parsing args

```zc
fn set_volume(_app: App*, args: JsonValue*) -> string {
    if args == NULL {
        return "{\"error\":\"no args\"}";
    }

    // get_int / get_float / get_string / get_bool return Option<T>
    let level_opt = args.get_int("level");
    if level_opt.is_none() {
        return "{\"error\":\"missing level\"}";
    }
    let level = level_opt.unwrap();

    // Do something with level...

    raw {
        static _Thread_local char buf[64];
        snprintf(buf, sizeof(buf), "{\"level\":%d,\"ok\":true}", level);
        return buf;
    }
    return "";
}
```

Available `JsonValue` accessors (see `std/json.zc`):

```zc
args.get_int(key: string) -> Option<int>
args.get_float(key: string) -> Option<double>
args.get_string(key: string) -> Option<string>
args.get_bool(key: string) -> Option<bool>
args.get(key: string) -> Option<JsonValue*>    // for nested objects/arrays
```

For arrays:
```zc
let items_opt = args.get("items");
if items_opt.is_some() {
    let items = items_opt.unwrap();
    let len = items.array_len();
    for i in 0..len {
        let item = items.array_get(i);
        // ...
    }
}
```

## Returning JSON strings

Service returns a **JSON-encoded string**. The runtime parses it client-side
so JS sees a proper object. Use a `_Thread_local` static buffer to avoid
per-call allocation:

```zc
fn get_stats(_app: App*, _args: JsonValue*) -> string {
    let cpu_percent = measure_cpu();
    let mem_mb = measure_memory();
    raw {
        static _Thread_local char buf[128];
        snprintf(buf, sizeof(buf),
            "{\"cpu\":%.1f,\"memory_mb\":%d}",
            cpu_percent, mem_mb);
        return buf;
    }
    return "";
}
```

`_Thread_local` is C11. Each thread (main, worker thread, etc.) gets its
own instance of `buf`, so two concurrent invokes on different threads
don't clobber each other. The buffer lives for the thread's lifetime —
the JS side copies the string out before the next call reuses it.

**Don't return a stack-allocated buffer pointer** — it'll be dead by the
time JS reads it.

**Don't `malloc`** without a plan to free — service calls are frequent,
and there's no auto-cleanup. Use `_Thread_local static` for fixed-size
responses, or build a larger JSON tree with `JsonValue` and serialize it.

## Services with state

For state that persists across calls, use a struct pointer and register
via `service.register()`:

```zc
struct CounterState {
    count: int;
}

let counter = CounterState{count: 0};

fn counter_increment(_app: App*, _args: JsonValue*) -> string {
    counter.count = counter.count + 1;
    raw {
        static _Thread_local char buf[32];
        snprintf(buf, sizeof(buf), "{\"count\":%d}", counter.count);
        return buf;
    }
    return "";
}

// In run_app():
app.service.add("increment", counter_increment);
```

For a globally mutable state struct, one service function per method
works fine. Multiple services can share the same struct by closing over
it at file scope.

## Services with lifecycle hooks

`service.register()` takes a struct pointer plus a `ServiceImpl` with
optional `startup` and `shutdown` callbacks:

```zc
struct DbService {
    handle: void*;
    connected: bool;
}

let db = DbService{handle: NULL, connected: false};

fn db_startup(ptr: void*) -> void {
    let self = (DbService*)ptr;
    self.handle = open_database();
    self.connected = true;
    println "db opened";
}

fn db_shutdown(ptr: void*) -> void {
    let self = (DbService*)ptr;
    if self.connected {
        close_database(self.handle);
    }
    println "db closed";
}

fn db_query(_app: App*, args: JsonValue*) -> string {
    // args parsing, run query, return result
    return "{\"rows\":[]}";
}

// In run_app():
app.service.register("db:query", (void*)&db, &ServiceImpl{
    handler: db_query,
    startup: db_startup,
    shutdown: db_shutdown,
});
```

`startup` fires at `app.run()` in registration order, before any webview
opens. `shutdown` fires in reverse order when the app terminates.

Use this pattern for services that need to acquire resources (DB
connections, file handles, system-wide subscriptions).

## Calling services from JS

```ts
import { Services } from "@zappdev/runtime";

// Returns a CancellablePromise
const result = await Services.invoke<{ rows: unknown[] }>("db:query", {
  sql: "SELECT * FROM users",
});
console.log(result.rows);

// Cancel a pending invoke
const p = Services.invoke("slowOp");
p.cancel();  // rejects the promise with a CancellationError
```

From a worker, `Services.invoke` takes the fast path — no IPC:

```ts
// In a worker (headless or webview-spawned)
const result = await Services.invoke<{ rows: unknown[] }>("db:query", {
  sql: "SELECT * FROM users",
});
// ~5 µs round-trip instead of ~135 µs
```

### Tight worker loops → use `Services.invokeSync`

Both `invoke` and `invokeSync` take the same direct host-object C call
in worker context — but `invoke` wraps the result in `Promise.resolve`
for API consistency with webview callers, which costs one microtask
drain per call. For a DB loop hitting a service 10,000 times that's
10,000 microtasks of pure overhead.

`invokeSync` returns the value directly:

```ts
// In a worker only — throws in a webview.
for (const id of ids) {
  const row = Services.invokeSync<Row>("db:fetchOne", { id });
  process(row);
}
```

Same ~5 µs round-trip as `invoke` in a worker, minus the microtask.
`invokeSync` throws if called from a webview context — if a handler
needs to run in both contexts, write it against `invoke` and let the
microtask cost fall to the rare webview caller.

## Thread safety

Service handlers run on the thread of the calling context:

- **Called from a webview**: runs on the main thread (after a short
  WKWebView IPC hop).
- **Called from a worker**: runs on the worker's thread (bare/zjs
  worker thread).

If you mutate shared state from a service and multiple contexts can
call concurrently, protect with a mutex or move the state into a
single-threaded owner (e.g. the main thread, enforced by
`dispatch_sync(main_queue)` or the Windows equivalent).

Zapp services **don't auto-serialize** calls — that's a design choice.
For most things (read-only services, atomic counters) no sync is needed.
For a DB connection pool, put the pool behind a mutex in your Zen-C
struct.

## Auto-generated bindings

Running `bun run generate` (or `zapp generate`) walks every `.zc` file
under `zapp/` — `app.zc` and any files imported by it — and scans for
`app.service.add("name", handler)` calls. It emits a TypeScript
wrapper per service under `src/zapp/`:

```ts
// src/zapp/Greet.ts (generated)
import { Services } from "@zappdev/runtime";

export async function greet(args?: Record<string, unknown>): Promise<unknown> {
    return Services.invoke("greet", args ?? {});
}
```

Plus an `index.ts` that re-exports every wrapper:

```ts
// src/zapp/index.ts (generated)
export { greet } from "./Greet";
export { keychainGet } from "./KeychainGet";
```

Used from UI code:

```ts
import { greet, keychainGet } from "./zapp";
await greet({ name: "World" });
await keychainGet({ key: "auth.token" });
```

### Fast path vs slow path — automatic

The wrapper always calls `Services.invoke(...)`, which detects the
calling context and takes the right transport:

- **Called from a webview**: ~135 µs — the call crosses the WKWebView /
  WebView2 postMessage boundary before reaching the native handler.
- **Called from a worker (headless or webview-spawned)**: ~5 µs — the
  call is a direct C function via the engine's host-object bridge. No
  IPC hop.

Same import, same call site, different speed per context. You don't
pick. If you need a *synchronous* call inside a worker,
`Services.invokeSync(name, args)` returns the value directly (throws
in a webview, where no sync path exists).

### Service names with separators

Service names commonly use a `namespace:operation` convention
(`keychain:get`, `db:query`, `file:read`). The generator camelCases
across `:`, `.`, and `-`, so `keychain:get` becomes a function named
`keychainGet` in a file called `KeychainGet.ts`. The invoke wire
name is preserved (`Services.invoke("keychain:get", ...)`).

### Regenerate on change

Re-run `bun run generate` after adding, renaming, or removing services.
The generator cleans stale `.ts`/`.js` files out of `src/zapp/` so
removing a `service.add` call removes its binding on the next
generate. Treat `src/zapp/` as fully generated — don't hand-edit;
your edits will be overwritten.

### Generated types — inferred args, annotated returns

The generated wrappers are typed, not `Record<string, unknown>`. Each
service emits a named `XxxArgs` / `XxxResult` interface (re-exported from
`src/zapp/index.ts`, so you can `import type { GreetResult }` and reuse
the shapes):

```ts
export interface GreetArgs { name?: string }
export interface GreetResult { greeting: string }
export async function greet(args?: GreetArgs): Promise<GreetResult> {
    return Services.invoke<GreetResult, GreetArgs>("greet", args ?? ({} as GreetArgs));
}
```

**Argument types are inferred from the handler body.** The generator
reads the `args.get_*("key")` calls and maps each to a field:

| Accessor | Inferred field |
|---|---|
| `args.get_string("k")` | `k?: string` |
| `args.get_int("k")` | `k?: number` |
| `args.get_float("k")` | `k?: number` |
| `args.get_bool("k")` | `k?: boolean` |
| `args.get("k")` (nested object/array) | `k?: unknown` |

Inferred fields are optional (handlers read args through the
`Option`/`is_some` pattern). Only reads off the handler's `args`
parameter are inferred — `someMap.get("x")` or a nested
`child.get_string("y")` are ignored.

**Return types come from an annotation.** Add a `// @zapp:returns { … }`
comment directly above the handler; the `{ … }` is emitted verbatim as
the `XxxResult` interface (any TypeScript type — nested, arrays, unions,
optional `?` — works, and `tsc` validates it):

```zc
// @zapp:returns { greeting: string }
fn greet(_app: App*, args: JsonValue*) -> string { … }
```

Without a `@zapp:returns`, the result type is `unknown`.

**Override inferred args** with `// @zapp:args { … }` when inference
can't see the shape (dynamic keys, nested objects, or to mark a field
required by omitting `?`):

```zc
// @zapp:args { id: number; filters: { tag: string }[] }
// @zapp:returns { rows: Row[] }
fn db_query(_app: App*, args: JsonValue*) -> string { … }
```

Precedence — args: `@zapp:args` override > inferred fields > loose
`Record<string, unknown>`; result: `@zapp:returns` > `unknown`. A handler
the generator can't locate falls back to the loose form (no regression).

**Typed escape hatch.** `Services.invoke` is generic on both return and
args, so you can call services directly with types when you're not using
a generated wrapper: `Services.invoke<{ token: string }, { key: string }>("keychain:get", { key })`.

## Keeping registration next to handlers

Small apps put `service.add(...)` calls directly in `run_app()` in
`app.zc`. Once you have a cluster of related services, move them into
their own `.zc` file under `zapp/services/` and expose one registration
helper:

```zc
// zapp/services/keychain.zc
import "app/app.zc";
import "services/keychain.h" as kc;

fn keychain_set(_app: App*, args: JsonValue*) -> string {
    if args == NULL {
        raw { return "{\"ok\":false,\"error\":\"no args\"}"; }
    }
    let key_opt = args.get_string("key");
    let val_opt = args.get_string("value");
    if key_opt.is_none() || val_opt.is_none() {
        raw { return "{\"ok\":false,\"error\":\"missing fields\"}"; }
    }
    return kc::keychain_write(key_opt.unwrap(), val_opt.unwrap());
}

fn keychain_get(_app: App*, args: JsonValue*) -> string {
    if args == NULL {
        raw { return "{\"value\":null,\"error\":\"no args\"}"; }
    }
    let key_opt = args.get_string("key");
    if key_opt.is_none() {
        raw { return "{\"value\":null,\"error\":\"missing key\"}"; }
    }
    return kc::keychain_read(key_opt.unwrap());
}

fn register_keychain_services(app: App*) -> void {
    app.service.add("keychain:set", keychain_set);
    app.service.add("keychain:get", keychain_get);
}
```

```zc
// zapp/app.zc
import "app/app.zc";
import "./services/keychain.zc";

fn run_app() -> int {
    let app = App::new(AppConfig{ /* … */ });
    register_keychain_services(&app);
    // … rest of setup …
    return app.run();
}
```

The generator picks up both `keychain:set` and `keychain:get` because
it walks every `.zc` file under `zapp/`, not just `app.zc`. Move as
many or as few services out of `app.zc` as you like — the scanning
and bindings work the same either way.

> **String-literal gotcha.** Zen-C string literals outside `raw { }`
> blocks use f-string syntax; plain braces must be escaped (`{{`/`}}`)
> and backslash escapes aren't parsed. Return JSON error literals from
> a `raw { }` block (as shown above) so you can use real JSON syntax
> and `\"` escapes without Zen-C reinterpreting them.

## Name reservations

Any method starting with `__` is reserved for the framework (dialog,
notification, window, menu, dock, dialog_save, etc.). Don't use `__`
prefixes for your own service names. Apart from that, any string works
— conventions like `namespace:operation` (`db:query`, `file:read`) are
useful for grouping but aren't required by the framework.

## Services in ObjC or C

Some system APIs are cleaner to use from ObjC than from Zen-C — Keychain,
AVFoundation, NSWorkspace, CoreBluetooth. Others live in plain C
libraries (libsqlite3, libcurl) that you'd rather use directly than
re-declare as Zen-C externs in every service handler.

You can drop `.m` files (macOS) or `.c` files (Windows) **anywhere under
your project's `zapp/` tree**, and the CLI auto-compiles and links them
into the final binary. No config needed. Every build, the CLI scans
`<project>/zapp/**/*.{m,c}` and appends them to the platform cflags.

### Recommended layout

```
zapp/
├── app.zc
├── build.zc
└── services/
    ├── keychain.h       # C API declaration (the interop surface)
    ├── keychain.m       # ObjC implementation — compiled by CLI
    └── keychain.zc      # Zen-C bridge — typed wrapper callers use
```

### Example: Keychain service

`zapp/services/keychain.h`:

```c
#ifndef KEYCHAIN_H
#define KEYCHAIN_H
const char* keychain_read(const char* service, const char* account);
int keychain_write(const char* service, const char* account, const char* value);
#endif
```

`zapp/services/keychain.m`:

```objc
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "keychain.h"

const char* keychain_read(const char* service, const char* account) {
    NSDictionary* query = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: [NSString stringWithUTF8String:service],
        (id)kSecAttrAccount: [NSString stringWithUTF8String:account],
        (id)kSecReturnData: @YES,
    };
    CFDataRef data = NULL;
    OSStatus st = SecItemCopyMatching((CFDictionaryRef)query, (CFTypeRef*)&data);
    if (st != errSecSuccess || !data) return NULL;

    static _Thread_local char buf[1024];
    NSData* nsData = (__bridge_transfer NSData*)data;
    NSString* str = [[NSString alloc] initWithData:nsData encoding:NSUTF8StringEncoding];
    strncpy(buf, [str UTF8String], sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    return buf;
}

int keychain_write(const char* service, const char* account, const char* value) {
    // SecItemAdd / SecItemUpdate logic here…
    return 0;
}
```

`zapp/services/keychain.zc` (typed Zen-C bridge — optional but
recommended):

```zc
import "services/keychain.h" as c;

fn keychain_read_zc(service: string, account: string) -> string {
    let v = c::keychain_read(service, account);
    if v == NULL { return ""; }
    raw { return v; }
    return "";
}

fn keychain_write_zc(service: string, account: string, value: string) -> int {
    return c::keychain_write(service, account, value);
}
```

`zapp/app.zc` uses the bridge:

```zc
import "app/app.zc";
import "services/keychain.zc";

fn get_token(_app: App*, args: JsonValue*) -> string {
    if args == NULL { return "{\"error\":\"no args\"}"; }
    let svc_opt = args.get_string("service");
    let acct_opt = args.get_string("account");
    if svc_opt.is_none() || acct_opt.is_none() {
        return "{\"error\":\"missing fields\"}";
    }
    let token = keychain_read_zc(svc_opt.unwrap(), acct_opt.unwrap());
    raw {
        static _Thread_local char buf[1280];
        snprintf(buf, sizeof(buf), "{\"token\":\"%s\"}", (const char*)token);
        return buf;
    }
    return "";
}
```

### Frameworks and libraries

If your `.m`/`.c` uses a system framework or external library, link it
from `zapp/build.zc`:

```zc
//> macos: framework: Security            # for Keychain
//> macos: framework: AVFoundation        # for camera/mic
//> macos: link: -lsqlite3                # plain library
```

### Why you need the bridging `.zc`

You don't technically — a service handler can call C functions directly
from a `raw { ... }` block. But the bridge pattern:

- Gives the rest of your Zen-C code typed signatures (`string` in/out
  instead of `const char*`).
- Keeps call sites in `app.zc` idiomatic (`keychain_read_zc(svc, acct)`
  vs. raw-block casts).
- Moves all the `const char*`/`NULL` handling into one place.

### Why you need the auto-scan

Without it, a naked `import "services/keychain.h"` in Zen-C generates C
that *declares* `keychain_read` but leaves the symbol undefined at link
time (`Undefined symbols: _keychain_read`). The CLI's scan of
`zapp/**/*.{m,c}` passes those files to `clang` so their implementations
end up in the final binary.

### Scope

The scan is bounded to `<project>/zapp/**`. Native code under `src/` (or
anywhere else in your project) is **not** compiled — `src/` is your JS/TS
bundle managed by Vite. If you want native code in a different location,
symlink it into `zapp/` or reshape your project layout.

## Common mistakes

### Returning a string literal with interpolation

```zc
// WRONG — Zen-C interpolation syntax interferes with JSON braces
return "{\"count\":{count}}";
```

Use a raw block with `snprintf`:
```zc
raw {
    static _Thread_local char buf[32];
    snprintf(buf, sizeof(buf), "{\"count\":%d}", count);
    return buf;
}
```

### Forgetting the empty fallback return

Every code path through a Zen-C function must return. A raw block with
`return buf;` doesn't count for Zen-C's flow analysis (it's opaque C),
so you need a trailing `return "";`:

```zc
fn example() -> string {
    raw {
        static _Thread_local char buf[32];
        snprintf(buf, sizeof(buf), "...");
        return buf;  // returns from the raw block + the Zen-C function
    }
    return "";  // needed for Zen-C's analysis
}
```

### Storing the `args` pointer past the handler return

The `JsonValue*` tree is freed by the caller after the handler returns.
Don't stash it. If you need the data later, extract + copy what you
need into your own struct.

### Using unicode / binary data without encoding

The service response is a JSON string — it must be valid UTF-8. Raw
binary bytes need base64 encoding. `JsonValue::stringify` handles
escaping for you; avoid hand-rolling JSON when the data contains
arbitrary strings.

## Reading and writing files from a service

Services frequently need to read, write, or list files — a config file,
a user-picked upload, a cached fetch result. Zapp exposes `app.fs.*`
for this with an allowlist model enforced at every call.

**Declare allowed paths in `zapp.config.ts`:**

```ts
export default defineConfig({
  name: "MyApp",
  fs: {
    allow: [
      "$userData",              // ~/Library/Application Support/<bundle-id>/
      "$temp",                  // NSTemporaryDirectory()
      "~/Documents/MyApp",      // absolute, recursive
    ],
  },
});
```

Path variables resolve at runtime:

| Variable | Resolves to |
|---|---|
| `$userData` / `$appData` | `~/Library/Application Support/<bundle-id>/` |
| `$cache` | `~/Library/Caches/<bundle-id>/` |
| `$temp` | `NSTemporaryDirectory()` |
| `$home` | `NSHomeDirectory()` |
| `$downloads` | `~/Downloads` (requires entitlement if sandboxed) |
| `$documents` | `~/Documents` (requires entitlement if sandboxed) |
| `~/...` | alias for `$home/...` |

**Use from a service handler:**

```zc
import "../fs/fs.zc";

fn handle_save_note(app: App*, args_json: string, _rid: int) -> string {
    let parsed = JsonValue::parse(args_json).unwrap();
    let body = parsed.get_string("body").unwrap();
    let ok = app.fs.write_file("$userData/notes/latest.md", body);
    if ok { return "{\"ok\":true}"; }
    return "{\"ok\":false}";
}
```

**Paths granted via `Dialog.openFile` extend the allowlist for the
session.** When the user picks a file, you can read it back through
`app.fs.read_file` without putting its directory in `zapp.config.ts`:

```ts
// webview or worker side
const { paths } = await Dialog.openFile({});
// paths[0] is now readable via a service that calls app.fs.read_file(...)
```

**API surface:**

```zc
app.fs.read_file(path: string) -> string       // "" on denial / not found
app.fs.write_file(path: string, data: string) -> bool
app.fs.append_file(path: string, data: string) -> bool
app.fs.exists(path: string) -> bool
app.fs.read_dir(path: string) -> string        // JSON: [{name, kind}, ...]
app.fs.mkdir(path: string, recursive: bool) -> bool
app.fs.remove(path: string) -> bool            // file or empty dir
app.fs.rmdir(path: string, recursive: bool) -> bool
app.fs.rename(from: string, to: string) -> bool
app.fs.copy(from: string, to: string) -> bool
app.fs.grant(path: string) -> void             // extend session allowlist
app.fs.expand(path: string) -> string          // $var → absolute
```

Every call expands `$vars` / `~/...` and prefix-matches against the
allowlist. Paths containing `..` segments are rejected outright. Denied
calls return `""` / `false` — layer your own error reporting on top if
you need to distinguish "denied" from "not found."

**Scope note:** `FS` is not available in the webview. Webview code
should go through a service (see [Calling services from
JS](#calling-services-from-js)) or use `Dialog.openFile` for
user-initiated reads. A worker-JS binding will land in a follow-up
alpha; until then, call FS from Zen-C service code.

## Other native APIs available from services

The same native primitives the JS runtime exposes are also reachable
from Zen-C as methods on the `App` struct (or the matching namespace).
This is the **native-first** half of every Zapp API: the C/Obj-C
function is the platform primitive; the Zen-C method is the idiomatic
caller-facing API; the TS runtime is a presentation layer on top. From
inside a service handler you can skip the bridge round-trip and call
the Zen-C method directly:

```zc
// Show a Finder reveal as part of a save flow.
fn handle_export_done(app: App*, args_json: string, _rid: int) -> string {
    let path_opt = JsonValue::parse(args_json).unwrap().get_string("path");
    if path_opt.is_some() {
        app.show_item_in_folder(path_opt.unwrap());
    }
    return "{\"ok\":true}";
}

// React to system theme changes from a worker.
let theme = app.get_theme();   // "light" | "dark"
```

**Currently available `App::*` methods** (mirrors the JS `App.*`
namespace):

```zc
app.open_external(url: string)            // browser
app.show_item_in_folder(path: string)     // Finder reveal
app.open_path(path: string)               // open with default app
app.trash_item(path: string)              // → Trash (allowlist-gated)
app.get_theme() -> string                 // "light" | "dark"
```

**`Workers::*`** static namespace (no instance — call directly):

```zc
Workers::terminate(id: string)            // by ID; "h-foo" for headless
```

**`Clipboard::*`** static namespace — read/write the system clipboard:

```zc
Clipboard::read_text() -> string          // "" if no text
Clipboard::write_text(text: string) -> bool
Clipboard::read_html() -> string
Clipboard::write_html(html: string) -> bool
Clipboard::read_files() -> string         // JSON array of paths, or "[]"
Clipboard::has(fmt: string) -> bool       // "text" | "html" | "image" | "files"
Clipboard::clear() -> void
```

Image bytes are intentionally absent from the Zen-C surface —
services that handle images typically work with file paths via FS +
Dialog grants. JS code gets `Clipboard.readImage()` for the
in-memory PNG case.

**`Shortcuts::*`** static namespace — system-wide hotkeys via
Carbon's `RegisterEventHotKey`:

```zc
Shortcuts::register(accelerator: string) -> bool
Shortcuts::unregister(accelerator: string) -> bool
Shortcuts::is_registered(accelerator: string) -> bool
Shortcuts::unregister_all() -> void
```

The native side dispatches `app:shortcut-triggered` events with
`{accelerator: "..."}` payload on every press. Zen-C consumers can
listen via `App::on(...)` for the corresponding event name.
Per-accelerator native callbacks are intentionally not part of this
API — function pointers across thread boundaries (Carbon dispatches
on main; services run wherever) are a footgun better solved by the
existing event system.

All of these are thin wrappers around the same C primitives the JS
side calls — same allowlist gating on `trash_item`, same path-var
expansion on the Finder methods, same shared-worker rejection on
`Workers::terminate`. Zen-C services pay no extra cost for using them.

## Further reading

- [`api-reference.md`](api-reference.md) — runtime API including Services
- [`architecture.md`](architecture.md) — how services fit into the bridge
- `std/json.zc` (in your Zen-C install) — full JsonValue API
