# Configuration Reference

App configuration lives in `zapp/zapp.config.ts`. Use the `defineConfig` helper for type-checked configuration.

## Basic Example

```ts
import { defineConfig } from "zapp";

export default defineConfig({
  name: "My App",
  identifier: "com.example.myapp",
  version: "1.0.0",
  icon: "assets/icon.png",
  description: "A desktop app built with Zapp",
  author: "Your Name",
});
```

## Full Example

```ts
import { defineConfig } from "zapp";

export default defineConfig({
  name: "My App",
  identifier: "com.example.myapp",
  version: "1.2.0",
  icon: "assets/icon.png",
  description: "A desktop app built with Zapp",
  author: "Your Name",

  macos: {
    minimumSystemVersion: "14.0",
    category: "public.app-category.developer-tools",
    iconLayers: "assets/AppIcon.icon",
  },

  security: {
    csp: "default-src 'self'; script-src 'self' 'unsafe-inline'",
    allowNavigation: ["https://example.com", "https://*.trusted.dev"],
  },
});
```

## Fields

### Top-Level

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Display name of the application |
| `identifier` | `string` | Unique app identifier in reverse-domain notation (e.g. `com.example.myapp`) |
| `version` | `string` | App version string |
| `icon` | `string` | Path to the app icon image |
| `description` | `string` | Short description of the app |
| `author` | `string` | Author name |

### `macos`

macOS-specific configuration.

| Field | Type | Description |
|-------|------|-------------|
| `minimumSystemVersion` | `string` | Minimum macOS version required (e.g. `"14.0"`) |
| `category` | `string` | App Store category UTI (e.g. `"public.app-category.developer-tools"`) |
| `iconLayers` | `string` | Path to a `.icon` folder containing liquid glass icon layers (macOS 26+) |

### `security`

Security and content policy settings.

| Field | Type | Description |
|-------|------|-------------|
| `csp` | `string` | Custom Content Security Policy applied to the WebView |
| `allowNavigation` | `string[]` | URL patterns the WebView is allowed to navigate to. Supports wildcards. |

## Web Content Inspector

The web content inspector (right-click > Inspect Element) is controlled by build mode, not by config. The behavior is determined by a numeric flag:

| Value | Behavior |
|-------|----------|
| `-1` | Inherit from build mode (inspector enabled in debug, disabled in release) |
| `0` | Always disabled |
| `1` | Always enabled |

In practice: `zapp dev` and `zapp build --debug` enable the inspector. `zapp build` (release) disables it. Override this in your native code if you need explicit control.
