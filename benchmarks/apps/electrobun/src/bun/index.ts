import { BrowserWindow, BrowserView } from "electrobun/bun";
import type { BenchSchema } from "../shared/schema";

// Define the bun-side RPC: one request, "ping", returning { pong }.
const rpc = BrowserView.defineRPC<BenchSchema>({
  handlers: {
    requests: {
      ping: () => ({ pong: Date.now() }),
    },
  },
});

// One non-resizable 400x300 window hosting the minimal ping view.
const win = new BrowserWindow({
  title: "Hello Electrobun",
  url: "views://mainview/index.html",
  frame: {
    width: 400,
    height: 300,
    x: 200,
    y: 200,
  },
  rpc,
});

// Open devtools on startup so bridge-bench.ts can be pasted into the
// console without any extra setup. Electrobun has no right-click inspect
// menu in the WKWebView it ships, so this is the only path into the
// console on a release build. Slightly later than window creation is
// fine — the webview attaches to the window synchronously after this.
setTimeout(() => {
  try {
    win.webview.openDevTools();
  } catch (err) {
    console.error("failed to open devtools:", err);
  }
}, 250);
