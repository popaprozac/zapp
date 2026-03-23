# Sync API

The `Sync` module provides cross-context synchronization primitives. It allows one context to wait for a notification from another, enabling coordination patterns like producer/consumer without polling.

## Import

```typescript
import { Sync } from "@zapp/runtime";
```

## Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `Sync.wait` | `(key: string, options?: SyncWaitOptions) => Promise<"notified" \| "timed-out">` | Waits until another context calls `Sync.notify` with the same key, or until the timeout expires. |
| `Sync.notify` | `(key: string, count?: number) => boolean` | Wakes up to `count` contexts waiting on the given key. Returns `true` if at least one waiter was notified. |

## Types

### SyncWaitOptions

```typescript
interface SyncWaitOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `timeoutMs` | `number` | `undefined` (no timeout) | Maximum milliseconds to wait before resolving with `"timed-out"`. |
| `signal` | `AbortSignal` | `undefined` | An `AbortSignal` that cancels the wait when aborted. The promise rejects with an `AbortError`. |

### Sync.notify parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `key` | `string` | required | The key to notify on. Must match the key passed to `Sync.wait`. |
| `count` | `number` | `1` | Number of waiting contexts to wake. Use `Infinity` to wake all. |

## Examples

### Basic wait and notify

```typescript
// Context A (consumer)
import { Sync } from "@zapp/runtime";

const result = await Sync.wait("data-ready");
if (result === "notified") {
  console.log("Data is ready, processing...");
}
```

```typescript
// Context B (producer)
import { Sync } from "@zapp/runtime";

await prepareData();
Sync.notify("data-ready");
```

### Timeout

```typescript
import { Sync } from "@zapp/runtime";

const result = await Sync.wait("update", { timeoutMs: 5000 });

if (result === "timed-out") {
  console.log("No update received within 5 seconds");
} else {
  console.log("Update received");
}
```

### Cancellation with AbortSignal

```typescript
import { Sync } from "@zapp/runtime";

const controller = new AbortController();

// Cancel the wait after user interaction
cancelButton.addEventListener("click", () => controller.abort());

try {
  const result = await Sync.wait("long-task", { signal: controller.signal });
  console.log("Task completed:", result);
} catch (err) {
  if (err.name === "AbortError") {
    console.log("Wait was cancelled by user");
  }
}
```

### Producer/consumer pattern

```typescript
// producer.ts (worker)
import { Sync, Events } from "@zapp/runtime";

async function produce() {
  while (true) {
    const batch = await fetchNextBatch();
    Events.emit("batch-available", batch);
    Sync.notify("work-available", Infinity); // wake all consumers
    await delay(1000);
  }
}

produce();
```

```typescript
// consumer.ts (worker)
import { Sync, Events } from "@zapp/runtime";

let latestBatch: any = null;

Events.on("batch-available", (batch) => {
  latestBatch = batch;
});

async function consume() {
  while (true) {
    await Sync.wait("work-available");
    if (latestBatch) {
      process(latestBatch);
      latestBatch = null;
    }
  }
}

consume();
```

### Notify all waiters

```typescript
// Wake up every context waiting on "refresh"
const woke = Sync.notify("refresh", Infinity);
console.log(`Notified ${woke ? "at least one" : "no"} waiter(s)`);
```

## Cross-Context Behavior

`Sync.wait` and `Sync.notify` work across all Zapp contexts:

- **Webview to webview**
- **Worker to webview**
- **Webview to worker**
- **Worker to worker**

Keys are global strings. Any context can wait on or notify any key.

## Why Not SharedArrayBuffer?

Zapp does not use `SharedArrayBuffer` and `Atomics` for cross-context synchronization because Zapp's architecture spans multiple engines (the webview engine and QuickJS for workers), which cannot share memory. The `Sync` module provides equivalent coordination semantics using the native runtime as a broker. See the [FAQ](../faq.md) for more details.
