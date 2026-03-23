# Services API

The `Services` module invokes native functions written in Zen-C from JavaScript. Services bridge the gap between your frontend/worker code and native platform capabilities, with auto-generated TypeScript bindings and capability-based access control.

## Import

```typescript
import { Services } from "@zapp/runtime";
```

After running `zapp generate`, you also get typed bindings:

```typescript
import { MyService } from "./generated/services";
```

## Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `Services.invoke` | `(method: string, args?: any) => Promise<any>` | Invokes a native service method by name. Returns a promise that resolves with the result or rejects on error. |

## Auto-Generated Bindings

The `zapp generate` command reads your Zen-C service definitions and produces TypeScript bindings with full type safety.

```bash
zapp generate
```

This creates typed wrappers so you do not need to use `Services.invoke()` directly:

```typescript
// generated/services.ts (auto-generated, do not edit)
export const FileSystem = {
  readFile(path: string): Promise<Uint8Array> {
    return Services.invoke("FileSystem.readFile", { path });
  },
  writeFile(path: string, data: Uint8Array): Promise<void> {
    return Services.invoke("FileSystem.writeFile", { path, data });
  },
};
```

**Usage with generated bindings:**

```typescript
import { FileSystem } from "./generated/services";

const data = await FileSystem.readFile("/tmp/config.json");
const text = new TextDecoder().decode(data);
```

## Native Side

### Registering a service

Services are registered in Zen-C using `service_add()`:

```c
// src/services/file_system.zc

const FileSystem = service_add("FileSystem", .{
    .readFile = readFile,
    .writeFile = writeFile,
});

fn readFile(ctx: *ServiceContext, args: ReadFileArgs) Result([]u8) {
    const file = try std.fs.openFile(args.path, .{});
    defer file.close();
    return try file.readAll(ctx.allocator);
}
```

### Service with lifecycle

Use `service_add_with_lifecycle()` for services that need initialization and cleanup:

```c
const Database = service_add_with_lifecycle("Database", .{
    .init = dbInit,
    .deinit = dbDeinit,
    .query = dbQuery,
    .execute = dbExecute,
});

fn dbInit(ctx: *ServiceContext) !void {
    // Open database connection
}

fn dbDeinit(ctx: *ServiceContext) void {
    // Close database connection
}
```

## Capability-Based Access Control

Services can restrict which contexts are allowed to invoke them. Capabilities are declared when registering the service and checked at runtime.

```c
const SecureStore = service_add("SecureStore", .{
    .capabilities = .{ .backend_only = true },
    .get = secureGet,
    .set = secureSet,
});
```

With `.backend_only = true`, attempts to invoke `SecureStore` methods from a webview or worker will be rejected.

## Error Handling

Service methods return `Result<T>`, which maps to a rejected promise on the JavaScript side.

**Native side:**

```c
fn divide(ctx: *ServiceContext, args: DivideArgs) Result(f64) {
    if (args.denominator == 0) {
        return error.DivisionByZero;
    }
    return @as(f64, args.numerator) / @as(f64, args.denominator);
}
```

**JavaScript side:**

```typescript
import { MathService } from "./generated/services";

try {
  const result = await MathService.divide(10, 0);
} catch (err) {
  console.error(err.message); // "DivisionByZero"
}
```

## Examples

### Using Services.invoke() directly

```typescript
import { Services } from "@zapp/runtime";

// Without generated bindings
const result = await Services.invoke("Clipboard.getText");
console.log("Clipboard:", result);

await Services.invoke("Clipboard.setText", { text: "Hello from Zapp" });
```

### Full workflow with generated bindings

```typescript
import { Database } from "./generated/services";

// Query returns typed results
const users = await Database.query("SELECT * FROM users WHERE active = ?", [true]);

for (const user of users) {
  console.log(user.name, user.email);
}

// Mutations
await Database.execute("UPDATE users SET last_login = ? WHERE id = ?", [Date.now(), userId]);
```

### Calling from a worker

Services are available in worker contexts:

```typescript
// workers/sync.ts
import { Services } from "@zapp/runtime";

const data = await Services.invoke("CloudSync.pull", { since: lastSync });
await Services.invoke("Database.mergeRecords", { records: data });
```

## Platform Notes

- Service methods are always asynchronous from the JavaScript side, even if the native implementation is synchronous. This is because calls cross the JS-to-native bridge.
- The `zapp generate` command should be re-run whenever you add, remove, or change the signature of a native service.
- Generated bindings are placed in your project's output directory (typically `./generated/services.ts`). Do not edit them manually.
