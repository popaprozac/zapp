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

## Thread safety

Service handlers run on the thread of the calling context:

- **Called from a webview**: runs on the main thread (after a short
  WKWebView IPC hop).
- **Called from a worker**: runs on the worker's thread (JSC worker
  queue or txiki libuv thread).

If you mutate shared state from a service and multiple contexts can
call concurrently, protect with a mutex or move the state into a
single-threaded owner (e.g. the main thread, enforced by
`dispatch_sync(main_queue)` or the Windows equivalent).

Zapp services **don't auto-serialize** calls — that's a design choice.
For most things (read-only services, atomic counters) no sync is needed.
For a DB connection pool, put the pool behind a mutex in your Zen-C
struct.

## Auto-generated bindings

Running `bun run generate` (or `zapp generate`) scans your source for
`app.service.add(...)` and `app.service.register(...)` calls, emits
typed TypeScript wrappers under `src/generated/`:

```ts
// src/generated/Greet.ts (auto)
import { Services } from "@zappdev/runtime";
export function greet(): Promise<string> {
  return Services.invoke("greet");
}
```

Used from UI:
```ts
import { greet } from "./generated/Greet";
console.log(await greet());
```

Re-run `bun run generate` after adding or renaming services to keep the
bindings current. The generator picks up the service name and emits a
typed wrapper — arguments and return type inference are coarse (it
can't read your Zen-C code), so you'll often hand-edit the generated
wrappers to add argument types, or just call `Services.invoke<T>(...)`
directly with inline types.

## Name reservations

Any method starting with `__` is reserved for the framework (dialog,
notification, window, menu, dock, dialog_save, etc.). Don't use `__`
prefixes for your own service names. Apart from that, any string works
— conventions like `namespace:operation` (`db:query`, `file:read`) are
useful for grouping but aren't required by the framework.

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

## Further reading

- [`api-reference.md`](api-reference.md) — runtime API including Services
- [`architecture.md`](architecture.md) — how services fit into the bridge
- `std/json.zc` (in your Zen-C install) — full JsonValue API
