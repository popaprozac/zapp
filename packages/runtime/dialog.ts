import { Events } from "./events";

export interface FileFilter {
  name: string;
  extensions: string[];
}

export interface OpenFileOptions {
  title?: string;
  defaultPath?: string;
  filters?: FileFilter[];
  multiple?: boolean;
  directory?: boolean;
}

export interface SaveFileOptions {
  title?: string;
  defaultPath?: string;
  defaultName?: string;
  filters?: FileFilter[];
}

export interface MessageOptions {
  title?: string;
  message: string;
  kind?: "info" | "warning" | "critical";
  buttons?: string[];
}

export interface OpenFileResult {
  ok: boolean;
  cancelled?: boolean;
  paths?: string[];
}

export interface SaveFileResult {
  ok: boolean;
  cancelled?: boolean;
  path?: string;
}

export interface MessageResult {
  ok: boolean;
  button: number;
}

export interface DialogAPI {
  openFile(options?: OpenFileOptions): Promise<OpenFileResult>;
  saveFile(options?: SaveFileOptions): Promise<SaveFileResult>;
  message(options: MessageOptions): Promise<MessageResult>;
}

let dialogSeq = 0;

function assertNotWorker(): void {
  const ctx = (globalThis as unknown as Record<symbol, unknown>)[Symbol.for("zapp.context")];
  if (ctx === "worker") {
    throw new Error("Dialog APIs are not available in a worker context.");
  }
}

function postDialog<T>(action: string, params: Record<string, unknown>): Promise<T> {
  return new Promise((resolve, reject) => {
    const requestId = `dialog-${Date.now()}-${++dialogSeq}`;
    const timer = setTimeout(() => {
      off();
      reject(new Error("Dialog timed out."));
    }, 300000);

    // Listen for the result via the bridge event system
    const off = Events.on(`__zapp:dialog:${requestId}`, (payload) => {
      clearTimeout(timer);
      const result = { ...(payload as Record<string, unknown>) };
      delete result.requestId;
      resolve(result as T);
    });

    // Post the request to native
    const handler = (globalThis as unknown as Record<string, Record<string, Record<string, { postMessage?: (m: string) => void }>>>)
      .webkit?.messageHandlers?.zapp;
    const chromeWebview = (globalThis as unknown as Record<string, Record<string, { postMessage?: (m: string) => void }>>)
      .chrome?.webview;

    const msg = `dialog\n${action}\n${JSON.stringify({ requestId, ...params })}`;

    if (handler?.postMessage) {
      handler.postMessage(msg);
    } else if (chromeWebview?.postMessage) {
      chromeWebview.postMessage(msg);
    } else {
      clearTimeout(timer);
      off();
      reject(new Error("Dialog bridge unavailable."));
    }
  });
}

export const Dialog: DialogAPI = {
  openFile(options: OpenFileOptions = {}): Promise<OpenFileResult> {
    assertNotWorker();
    return postDialog<OpenFileResult>("openFile", options as unknown as Record<string, unknown>);
  },

  saveFile(options: SaveFileOptions = {}): Promise<SaveFileResult> {
    assertNotWorker();
    return postDialog<SaveFileResult>("saveFile", options as unknown as Record<string, unknown>);
  },

  message(options: MessageOptions): Promise<MessageResult> {
    assertNotWorker();
    return postDialog<MessageResult>("message", options as unknown as Record<string, unknown>);
  },
};
