/**
 * Dialog — native file and message dialogs.
 *
 * @example
 * ```ts
 * import { Dialog } from "@zappdev/runtime";
 *
 * const result = await Dialog.openFile({ multiple: true, filters: [{ name: "Images", extensions: ["png", "jpg"] }] });
 * if (!result.cancelled) console.log(result.paths);
 *
 * const save = await Dialog.saveFile({ defaultName: "doc.txt" });
 * const msg = await Dialog.message({ message: "Are you sure?", buttons: ["Yes", "No"] });
 * ```
 */

import { getBridge } from "./bridge";

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
  message: string;
  title?: string;
  kind?: "info" | "warning" | "critical";
  buttons?: string[];
}

export interface OpenFileResult {
  cancelled: boolean;
  paths?: string[];
}

export interface SaveFileResult {
  cancelled: boolean;
  path?: string;
}

export interface MessageResult {
  button: number;
}

export const Dialog = {
  async openFile(options?: OpenFileOptions): Promise<OpenFileResult> {
    const result = await getBridge().invoke("__dialog:open", options as any);
    return result as OpenFileResult;
  },

  async saveFile(options?: SaveFileOptions): Promise<SaveFileResult> {
    const result = await getBridge().invoke("__dialog:save", options as any);
    return result as SaveFileResult;
  },

  async message(options: MessageOptions): Promise<MessageResult> {
    const result = await getBridge().invoke("__dialog:message", options as any);
    return result as MessageResult;
  },
};
