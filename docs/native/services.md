# Services (Native)

Services are native Zen-C functions exposed to JavaScript via the bridge. They provide typed RPC from your frontend to your native backend.

## Defining a Service

```zc
fn greet(app: App*, args: string) -> string {
    // args is the JSON payload from JS
    // Return JSON string as the result
    return args;
}

// Register in run_app():
app.service.add("greet", greet);
```

The handler signature is always `fn*(App*, string) -> string`.

## Service with Lifecycle

For services that need startup/shutdown hooks:

```zc
fn db_handler(app: App*, args: string) -> string {
    // Handle request
    return "{{}}";
}

fn db_startup(app: App*) -> bool {
    // Initialize database connection
    // Return false to abort app startup
    return true;
}

fn db_shutdown(app: App*) -> void {
    // Close database connection
}

// Register:
app.service.add_with_lifecycle(
    "db.query",      // name
    db_handler,       // handler
    db_startup,       // startup (called before app.run())
    db_shutdown,      // shutdown (called after app.run() exits)
    true,             // public (accessible from JS)
    ""                // capability (empty = no capability required)
);
```

## Capability-based Access Control

Services can require a capability token:

```zc
app.service.add_with_lifecycle(
    "admin.reset",
    admin_handler,
    NULL, NULL,
    true,
    "admin"  // Requires "admin" capability
);
```

The JS caller must provide the matching capability in the RPC metadata.

## Return Type: Result<T>

`service_invoke_with_policy` returns `Result<string>`:

```zc
let result = service_invoke_with_policy(app, method, payload, capability);
if result.is_err() {
    let code = result.err; // "NOT_FOUND", "UNAUTHORIZED", etc.
}
let value = result.unwrap(); // The JSON result string
```

Error codes:
| Code | Meaning |
|---|---|
| `INVALID_METHOD` | Method name contains invalid characters |
| `BAD_REQUEST` | Payload exceeds 64 KB limit |
| `NOT_FOUND` | No service registered with that name |
| `UNAUTHORIZED` | Service is not public, or capability mismatch |
| `INTERNAL_ERROR` | Handler not available |

## Auto-Generated TypeScript Bindings

Run `zapp generate` to scan your Zen-C services and generate typed TypeScript bindings:

```bash
zapp generate --root .
```

This produces files in `src/generated/`:

```ts
// src/generated/Greet.ts (auto-generated)
import { Services } from "@zapp/runtime";

export class Greet {
    static async greet(args: unknown): Promise<unknown> {
        return Services.invoke("greet", args);
    }
}
```

Usage:
```ts
import { Greet } from "./generated";

const result = await Greet.greet({ name: "World" });
```

## Constraints

- Service names: alphanumeric, dots, underscores, hyphens only (max 96 chars)
- Payload size: max 64 KB
- Max registered services: 128
- Handler runs on the main thread — keep it fast
