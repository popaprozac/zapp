# Worker API

The `Worker` and `SharedWorker` modules run JavaScript in background threads, keeping the UI responsive. Zapp Workers are distinct from standard Web Workers and offer tighter integration with the Zapp runtime.

## Import

```typescript
import { Worker, SharedWorker } from "@zapp/runtime";
```

## Zapp Workers vs Web Workers

| | Zapp Worker | Web Worker |
|---|---|---|
| **Engine** | QuickJS (embedded) | WebView JS engine |
| **Startup** | Fast (no webview) | Slower (spins up webview context) |
| **Access to Zapp APIs** | Full (Events, Sync, Services, Window.create) | Limited (only postMessage bridge) |
| **DOM** | None | None |
| **Use case** | Background tasks, services, coordination | CPU work needing full Web API compatibility |

**When to use Zapp Workers:** background processing, long-running services, cross-context coordination, or anything that benefits from fast startup and small memory footprint.

**When to use Web Workers:** tasks that require Web APIs not available in QuickJS (e.g. Canvas offscreen, WASM with Web API bindings).

## Worker

### Constructor

```typescript
const worker = new Worker("workers/processor.ts");
```

Creates a new Zapp Worker from the given script path (relative to your project root).

### Properties and Methods

| Member | Type | Description |
|--------|------|-------------|
| `postMessage` | `(data: any) => void` | Sends a message to the worker. |
| `onmessage` | `((event: { data: any }) => void) \| null` | Handler for messages received from the worker. |
| `terminate` | `() => void` | Immediately stops the worker. |

### Example

**Main context:**

```typescript
import { Worker } from "@zapp/runtime";

const worker = new Worker("workers/analysis.ts");

worker.onmessage = (event) => {
  console.log("Result:", event.data);
};

worker.postMessage({ type: "analyze", dataset: "sales-2025" });
```

**Worker script (`workers/analysis.ts`):**

```typescript
self.onmessage = (event) => {
  const { type, dataset } = event.data;

  if (type === "analyze") {
    const result = runAnalysis(dataset);
    self.postMessage(result);
  }
};
```

## SharedWorker

A `SharedWorker` can be connected to from multiple contexts. Each connection gets its own `port`.

### Constructor

```typescript
const shared = new SharedWorker("workers/cache.ts");
```

### Port API

| Member | Type | Description |
|--------|------|-------------|
| `shared.port.postMessage` | `(data: any) => void` | Sends a message through the port. |
| `shared.port.onmessage` | `((event: { data: any }) => void) \| null` | Handler for incoming messages on the port. |
| `shared.port.start` | `() => void` | Starts receiving messages (called automatically if `onmessage` is set). |
| `shared.port.close` | `() => void` | Closes the port. |

### Example

**Main context (multiple webviews can connect):**

```typescript
import { SharedWorker } from "@zapp/runtime";

const shared = new SharedWorker("workers/cache.ts");

shared.port.onmessage = (event) => {
  console.log("Cached value:", event.data);
};

shared.port.postMessage({ action: "get", key: "user-prefs" });
```

**Shared worker script (`workers/cache.ts`):**

```typescript
const cache = new Map<string, any>();

self.onconnect = (event) => {
  const port = event.ports[0];

  port.onmessage = (msg) => {
    const { action, key, value } = msg.data;

    if (action === "set") {
      cache.set(key, value);
    } else if (action === "get") {
      port.postMessage(cache.get(key) ?? null);
    }
  };
};
```

## Channel API

The Channel API provides structured, typed messaging between contexts.

```typescript
import { Worker } from "@zapp/runtime";

// Main context
const worker = new Worker("workers/data.ts");

// Send typed messages
worker.postMessage({ channel: "fetch", payload: { url: "/api/users" } });

// Receive typed responses
worker.onmessage = (event) => {
  const { channel, payload } = event.data;
  if (channel === "fetch-result") {
    updateUI(payload);
  }
};
```

This pattern is a convention built on top of `postMessage` -- structure your messages with `channel` and `payload` fields for clean typed communication.

## Build Configuration

Zapp Workers use the QuickJS engine by default. The engine is included automatically when your project uses `Worker` or `SharedWorker`.

To remove QuickJS from the build (if you only use Web Workers), remove `ZAPP_WORKER_ENGINE_QJS` from your `build.zc`:

```
// build.zc
features: [
  // "ZAPP_WORKER_ENGINE_QJS",  // commented out to remove QuickJS
],
```

## Available APIs in Worker Context

The following APIs are available inside Zapp Worker scripts:

| API | Notes |
|-----|-------|
| `fetch` | Full HTTP client. |
| `WebSocket` | WebSocket client. |
| `setTimeout` / `setInterval` | Standard timers. |
| `clearTimeout` / `clearInterval` | Timer cancellation. |
| `TextEncoder` / `TextDecoder` | UTF-8 encoding and decoding. |
| `URL` / `URLSearchParams` | URL parsing. |
| `crypto.getRandomValues` | Cryptographic random bytes. |
| `crypto.randomUUID` | UUID v4 generation. |
| `atob` / `btoa` | Base64 encoding and decoding. |
| `console` | Logging (output goes to the app's log). |
| `Events` | Cross-context events. See [Events API](events.md). |
| `Sync` | Cross-context synchronization. See [Sync API](sync.md). |
| `Services` | Native service invocation. See [Services API](services.md). |
| `Window.create` | Create windows (but not `Window.current()`). |

**Not available in workers:** DOM, `Dialog`, `Window.current()`.
