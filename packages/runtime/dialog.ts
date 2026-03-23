import { Events } from "./events";

/** A file type filter for open/save dialogs. */
export interface FileFilter {
  /** Display name for the filter (e.g. "Images"). */
  name: string;
  /** Allowed file extensions without dots (e.g. ["png", "jpg"]). */
  extensions: string[];
}

/** Options for the open-file dialog. */
export interface OpenFileOptions {
  /** Dialog window title. */
  title?: string;
  /** Initial directory or file path. */
  defaultPath?: string;
  /** File type filters shown in the dialog. */
  filters?: FileFilter[];
  /** Whether the user can select multiple files. */
  multiple?: boolean;
  /** Whether to select directories instead of files. */
  directory?: boolean;
}

/** Options for the save-file dialog. */
export interface SaveFileOptions {
  /** Dialog window title. */
  title?: string;
  /** Initial directory path. */
  defaultPath?: string;
  /** Default file name pre-filled in the dialog. */
  defaultName?: string;
  /** File type filters shown in the dialog. */
  filters?: FileFilter[];
}

/** Options for a message dialog (alert/confirm). */
export interface MessageOptions {
  /** Dialog window title. */
  title?: string;
  /** The message body text. */
  message: string;
  /** Severity level controlling the dialog icon. */
  kind?: "info" | "warning" | "critical";
  /** Button labels to display (e.g. ["OK", "Cancel"]). */
  buttons?: string[];
}

/** Result from an open-file dialog. */
export interface OpenFileResult {
  /** Whether the dialog completed successfully. */
  ok: boolean;
  /** True if the user cancelled the dialog. */
  cancelled?: boolean;
  /** Selected file or directory paths. */
  paths?: string[];
}

/** Result from a save-file dialog. */
export interface SaveFileResult {
  /** Whether the dialog completed successfully. */
  ok: boolean;
  /** True if the user cancelled the dialog. */
  cancelled?: boolean;
  /** The chosen save path. */
  path?: string;
}

/** Result from a message dialog. */
export interface MessageResult {
  /** Whether the dialog completed successfully. */
  ok: boolean;
  /** Zero-based index of the button the user clicked. */
  button: number;
}

/** API for showing native file and message dialogs. */
export interface DialogAPI {
  /** Show a native open-file dialog. */
  openFile(options?: OpenFileOptions): Promise<OpenFileResult>;
  /** Show a native save-file dialog. */
  saveFile(options?: SaveFileOptions): Promise<SaveFileResult>;
  /** Show a native message dialog (alert/confirm). */
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

/** The singleton dialog API instance. Not available in worker contexts. */
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
