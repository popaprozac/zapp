/** Focused frontend API for trusted native file selection. */

import { Dialog, type FileFilter } from "./dialog";
import { ensurePermission } from "./permissions";

export interface OpenDialogOptions {
  title?: string;
  defaultPath?: string;
  filters?: FileFilter[];
}

export interface SaveDialogOptions extends OpenDialogOptions {
  defaultName?: string;
}

export interface DialogManager {
  /** Select one file. User cancellation resolves to `null`. */
  openFile(options?: OpenDialogOptions): Promise<string | null>;

  /** Select one or more files. User cancellation resolves to `null`. */
  openFiles(options?: OpenDialogOptions): Promise<readonly string[] | null>;

  /** Select one directory. User cancellation resolves to `null`. */
  openDirectory(options?: OpenDialogOptions): Promise<string | null>;

  /** Select one destination path. User cancellation resolves to `null`. */
  saveFile(options?: SaveDialogOptions): Promise<string | null>;
}

/** Stable dialog manager used by the focused Application facade. */
export const applicationDialogs: DialogManager = {
  async openFile(options = {}): Promise<string | null> {
    ensurePermission("dialog");
    const result = await Dialog.openFile({
      ...options,
      multiple: false,
      directory: false,
    });
    if (result.cancelled) return null;
    return result.paths?.[0] ?? null;
  },

  async openFiles(options = {}): Promise<readonly string[] | null> {
    ensurePermission("dialog");
    const result = await Dialog.openFile({
      ...options,
      multiple: true,
      directory: false,
    });
    if (result.cancelled) return null;
    return Object.freeze([...(result.paths ?? [])]);
  },

  async openDirectory(options = {}): Promise<string | null> {
    ensurePermission("dialog");
    const result = await Dialog.openFile({
      ...options,
      multiple: false,
      directory: true,
    });
    if (result.cancelled) return null;
    return result.paths?.[0] ?? null;
  },

  async saveFile(options = {}): Promise<string | null> {
    ensurePermission("dialog");
    const result = await Dialog.saveFile(options);
    if (result.cancelled) return null;
    return result.path ?? null;
  },
};
