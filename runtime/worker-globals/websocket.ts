// Install WHATWG-shaped `WebSocket` global from `bare-ws`.
//
// `bare-ws` exports a class compatible with the WHATWG WebSocket
// interface (open/close/message/error events, send, close, readyState).
// Once bound, code written for browsers Just Works:
//
//   const ws = new WebSocket('wss://example.com/ws');
//   ws.onmessage = e => { ... };
import { bindGlobal, tryRequire } from "./_install";

const mod = tryRequire("bare-ws");
if (mod) {
  bindGlobal("WebSocket", mod.default ?? mod.WebSocket);
}
