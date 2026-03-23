# Dialog API

The `Dialog` module provides native file dialogs and message boxes. All dialog methods are asynchronous and return a `Promise` that resolves when the user completes or dismisses the dialog.

## Import

```typescript
import { Dialog } from "@zapp/runtime";
```

## Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `Dialog.openFile` | `(options?: OpenFileOptions) => Promise<OpenFileResult>` | Shows a native file-open dialog. |
| `Dialog.saveFile` | `(options?: SaveFileOptions) => Promise<SaveFileResult>` | Shows a native file-save dialog. |
| `Dialog.message` | `(options: MessageOptions) => Promise<MessageResult>` | Shows a native message box. |

## Types

### OpenFileOptions

```typescript
interface OpenFileOptions {
  title?: string;
  defaultPath?: string;
  filters?: FileFilter[];
  multiple?: boolean;
  directory?: boolean;
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | `string` | `"Open"` | Dialog window title. |
| `defaultPath` | `string` | `""` | Initial directory or file path. |
| `filters` | `FileFilter[]` | `[]` | File type filters shown in the dialog dropdown. |
| `multiple` | `boolean` | `false` | Allow selecting multiple files. |
| `directory` | `boolean` | `false` | Select directories instead of files. |

### OpenFileResult

```typescript
interface OpenFileResult {
  cancelled: boolean;
  paths: string[];
}
```

### SaveFileOptions

```typescript
interface SaveFileOptions {
  title?: string;
  defaultPath?: string;
  filters?: FileFilter[];
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | `string` | `"Save"` | Dialog window title. |
| `defaultPath` | `string` | `""` | Initial directory or suggested file name. |
| `filters` | `FileFilter[]` | `[]` | File type filters shown in the dialog dropdown. |

### SaveFileResult

```typescript
interface SaveFileResult {
  cancelled: boolean;
  path: string | null;
}
```

### FileFilter

```typescript
interface FileFilter {
  name: string;
  extensions: string[];
}
```

Example: `{ name: "Images", extensions: ["png", "jpg", "gif"] }`

### MessageOptions

```typescript
interface MessageOptions {
  title: string;
  message: string;
  kind?: "info" | "warning" | "error";
  buttons?: string[];
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | `string` | required | Title of the message box. |
| `message` | `string` | required | Body text of the message box. |
| `kind` | `"info" \| "warning" \| "error"` | `"info"` | Icon and style of the dialog. |
| `buttons` | `string[]` | `["OK"]` | Labels for the dialog buttons. |

### MessageResult

```typescript
interface MessageResult {
  buttonIndex: number;
}
```

The `buttonIndex` corresponds to the position in the `buttons` array (zero-based).

## Examples

### Opening a single file

```typescript
import { Dialog } from "@zapp/runtime";

const result = await Dialog.openFile({
  title: "Select a document",
  filters: [
    { name: "Documents", extensions: ["pdf", "docx", "txt"] },
    { name: "All Files", extensions: ["*"] },
  ],
});

if (!result.cancelled) {
  console.log("Selected:", result.paths[0]);
}
```

### Opening multiple files

```typescript
const result = await Dialog.openFile({
  multiple: true,
  filters: [{ name: "Images", extensions: ["png", "jpg", "gif", "webp"] }],
});

if (!result.cancelled) {
  for (const path of result.paths) {
    loadImage(path);
  }
}
```

### Selecting a directory

```typescript
const result = await Dialog.openFile({
  title: "Choose export folder",
  directory: true,
});

if (!result.cancelled) {
  exportTo(result.paths[0]);
}
```

### Saving a file

```typescript
const result = await Dialog.saveFile({
  title: "Save project",
  defaultPath: "untitled.zproj",
  filters: [{ name: "Zapp Project", extensions: ["zproj"] }],
});

if (!result.cancelled && result.path) {
  await writeFile(result.path, projectData);
}
```

### Confirmation message box

```typescript
const result = await Dialog.message({
  title: "Unsaved Changes",
  message: "You have unsaved changes. Do you want to save before closing?",
  kind: "warning",
  buttons: ["Save", "Don't Save", "Cancel"],
});

if (result.buttonIndex === 0) {
  await save();
} else if (result.buttonIndex === 2) {
  // User cancelled, do nothing
  return;
}
```

### Error message

```typescript
await Dialog.message({
  title: "Error",
  message: "Failed to open the file. It may be corrupted or in use by another application.",
  kind: "error",
});
```

## Context Restrictions

- Dialog methods are **not available** in worker contexts. Calling `Dialog.openFile()`, `Dialog.saveFile()`, or `Dialog.message()` from a worker will throw an error.
- Dialogs must be invoked from a webview or the main backend context.
