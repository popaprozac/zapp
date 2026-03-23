# App API

The `App` module controls the application lifecycle, global configuration, and top-level behavior such as quitting, hiding, and setting the application menu.

## Import

```typescript
import { App } from "@zapp/runtime";
```

## Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `getConfig` | `() => AppConfig` | Returns the current application configuration. |
| `onReady` | `(callback: () => void) => void` | Registers a callback that fires once the app is fully initialized and the native layer is ready. |
| `quit` | `() => void` | Quits the application and closes all windows. |
| `hide` | `() => void` | Hides the application (macOS: hides from Dock; Windows: minimizes all windows). |
| `show` | `() => void` | Restores application visibility after a `hide()` call. |
| `openExternal` | `(url: string) => void` | Opens a URL in the user's default browser or associated application. |
| `setMenu` | `(menu: MenuHandle) => void` | Sets the application-level menu bar. See [Menu API](menu.md). |

## Types

### AppConfig

```typescript
interface AppConfig {
  name: string;
  version: string;
  identifier: string;
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | The display name of the application. |
| `version` | `string` | The application version string. |
| `identifier` | `string` | The unique application identifier (e.g. `"com.example.myapp"`). |

## Examples

### Basic lifecycle

```typescript
import { App } from "@zapp/runtime";

App.onReady(() => {
  const config = App.getConfig();
  console.log(`${config.name} v${config.version} is ready`);
});
```

### Opening an external URL

```typescript
import { App } from "@zapp/runtime";

App.openExternal("https://zapp.dev/docs");
```

### Setting the application menu

```typescript
import { App } from "@zapp/runtime";
import { Menu } from "@zapp/runtime";

const menu = Menu.build([
  { role: "appMenu" },
  {
    label: "File",
    submenu: [
      { label: "New", accelerator: "CmdOrCtrl+N", id: "file-new" },
      { type: "separator" },
      { label: "Quit", accelerator: "CmdOrCtrl+Q", action: () => App.quit() },
    ],
  },
]);

App.setMenu(menu);
```

### Quitting the application

```typescript
import { App } from "@zapp/runtime";

function handleFatalError(err: Error) {
  console.error("Fatal:", err);
  App.quit();
}
```

## Platform Notes

- **macOS**: `App.hide()` uses the native hide behavior (Cmd+H). The app remains in the Dock.
- **Windows**: `App.hide()` minimizes all application windows.
- `App.onReady()` should be called early in your entry point. If the app is already ready when called, the callback fires on the next microtask.
