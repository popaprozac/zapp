# ZappWorker Compliance Matrix

This document defines how Zapp's built-in `Worker` and `SharedWorker` implementations align with native Web Worker behavior, where we intentionally deviate, and known constraints.

## Target Behavior

The fundamental goal is that Zapp workers should feel identical to native Web Workers for most standard desktop application workloads. The API surfaces are mirrored in TypeScript, and we automatically shadow `window.Worker` and `window.SharedWorker` in the main webview to transparently execute worker logic in Zapp's embedded JavaScript engine.

## API Matrix

### Regular `Worker`

| Area | Native Worker | Zapp Worker | Notes |
|---|---|---|---|
| Constructor input | `string \| URL` | Supported | `new Worker(new URL("...", import.meta.url))` is fully supported. |
| Constructor options | `{ type, name, credentials }` | Ignored | Passed options are ignored by the internal runtime. We always assume JS/ES execution. |
| `postMessage(data)` | Yes | Yes | Objects are natively serialized via JSON. |
| Transferables in `postMessage` | Yes | **No** | Transferables (`ArrayBuffer`, `MessagePort`, etc.) are not currently supported due to cross-bridge JSON serialization. |
| `onmessage` | Yes | Yes | |
| `onerror` | Yes | Yes | Reconstructs JS errors with `message`, `filename`, `lineno`, and `colno`. |
| `onclose` | **No** | **Yes** | **Custom ergonomic extension**. Allows parent context to listen to when a child worker self-terminates (`worker.close()`) or is terminated. |
| `add/removeEventListener` | Yes | Yes | Supports `message`, `error`, and `close`. Supports `once: true`. |
| `dispatchEvent` | Yes | Partial | Supports emitting standard types but CustomEvent bubbling is limited. |
| `terminate()` | Yes | Yes | Fully supported. Instantly terminates the JSContext and invalidates all callbacks. |

### `SharedWorker`

| Area | Native Worker | Zapp SharedWorker | Notes |
|---|---|---|---|
| Constructor input | `string \| URL` | Supported | `new SharedWorker(...)` is fully supported. |
| Port property | Yes (`.port`) | Yes | Exposes `.port.postMessage`, `.port.onmessage`, `.port.start()`, etc. |
| Port `start()` | **Required** | **No-op** | **Intentional deviation**. In Zapp, `SharedWorker`s are actively connected immediately upon initialization. `start()` and `close()` on the port are no-ops provided strictly for structural API compatibility. |
| `onconnect` | Yes | Yes | Fires in the worker context when a new client attaches. Receives a `MessageEvent` with `ports[0]`. |

## Zapp Custom Extensions

Zapp provides several ergonomic enhancements over standard web workers that drastically reduce boilerplate for inter-thread communication.

1. **Channel Based Messaging**: 
   Both `Worker` and `SharedWorker` instances provide `send(channel: string, data: any)` and `receive(channel: string, handler: Function)` methods. This eliminates the need to manually build switch-case statements inside standard `onmessage` blocks.
2. **Targeted Replies (SharedWorkers)**:
   The `receive` handler in a worker receives a `reply` function as a second argument (`(data, reply) => { ... }`). Calling `reply(channel, data)` automatically routes the message *only* to the specific Webview or parent that originated the call, acting like a private port without having to manually manage an array of `MessagePort`s.
3. **Global Event Bus**:
   Workers have full access to `@zapp/runtime`'s `Events.emit` and `Events.on`. Emitting an event broadcasts to all Webviews and all other Workers instantly.
4. **Self Termination**:
   Workers can call `self.close()`, which tears down the background engine and notifies the parent context via the custom `onclose` event.

## Environment Constraints & Global Scope

Zapp workers execute in a standalone engine (JavaScriptCore on macOS, QuickJS on Windows). They do *not* have access to the DOM or the `window` object. 

The following polyfills and globals are provided:
- **Timers**: `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval` (compliant scheduling and execution order).
- **Fetch API**: Natively backed `fetch`, `Headers`, and `Response`. Note: `body` is supported for textual/JSON data, but streaming and complex binary transfers are limited.
- **Crypto API**: Natively backed `crypto.getRandomValues` and `crypto.randomUUID()`. WebCrypto (`crypto.subtle`) is not yet implemented.
- **Events**: `Event`, `CustomEvent`, and `EventTarget`.
- **Max Workers**: Zapp limits the maximum number of concurrent workers to prevent memory exhaustion. Exceeding `AppConfig.maxWorkers` emits an `error` event.

## Debugging

If you need to bypass Zapp's worker shadowing to test native web workers in the Webview, set `globalThis.__ZAPP_DISABLE_WORKER_SHADOW__ = true` in your main webview entry point *before* the framework initializes.