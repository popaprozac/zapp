/** Focused frontend API for authority-checked application files. */

import { getBridge } from "./bridge";
import { ensurePermission } from "./permissions";

export { FileError } from "./file-errors";
export type {
  FileErrorPayload,
  FileOperation,
} from "./file-errors";

export interface FileManager {
  /** Read one authorized UTF-8 text file without blocking the UI thread. */
  readText(path: string): Promise<string>;

  /** Write one authorized UTF-8 text file without blocking the UI thread. */
  writeText(path: string, contents: string): Promise<void>;
}

function textResult(value: unknown): string {
  if (typeof value === "string") return value;
  throw new TypeError("native Zapp returned a non-string readText result");
}

/** Stable files manager used by the focused Application facade. */
export const applicationFiles: FileManager = {
  async readText(path: string): Promise<string> {
    ensurePermission("fs:read");
    return textResult(await getBridge().invoke(
      "__zapp:files:read-text",
      { path },
    ));
  },

  async writeText(path: string, contents: string): Promise<void> {
    ensurePermission("fs:write");
    await getBridge().invoke(
      "__zapp:files:write-text",
      { path, contents },
    );
  },
};
