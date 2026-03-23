# Getting Started

Build native desktop apps with Zen-C and a system WebView. Final binary size starts at ~173 KB.

## Prerequisites

| Tool | Purpose |
|------|---------|
| **Zen-C compiler** (`zc`) | Compiles native code |
| **Bun** | JS runtime for tooling and frontend builds |
| **Xcode CLI Tools** (macOS) | System frameworks and linker |
| **Visual Studio Build Tools** (Windows) | MSVC compiler and Windows SDK |

## Create a Project

```bash
zapp init my-app
cd my-app
```

This scaffolds a new project using the `svelte-ts` template by default. You can choose a different template with `--template`:

```bash
zapp init my-app --template vanilla
```

## Project Structure

```
my-app/
  zapp/
    build.zc           # Build entry point
    app.zc             # Application code (windows, menus, events)
    zapp.config.ts     # App configuration (name, version, icons, etc.)
  src/                 # Frontend source (HTML, CSS, JS/TS, Svelte, etc.)
  package.json
```

- **`zapp/build.zc`** -- Entry point that the Zen-C compiler uses to build the native binary.
- **`zapp/app.zc`** -- Your application logic: creating windows, handling events, defining menus.
- **`zapp/zapp.config.ts`** -- Configuration for your app's metadata, icons, and platform-specific settings.
- **`src/`** -- Your frontend code, built by Vite during dev and production builds.

## Development

```bash
zapp dev
```

This starts Vite for the frontend and compiles the native code. The app window opens automatically with hot-reloading for frontend changes.

## Production Build

```bash
zapp build --brotli
```

Compiles the native binary and embeds compressed frontend assets directly into the executable. The `--brotli` flag enables Brotli compression for smaller binaries.

## Package

```bash
zapp package --brotli
```

Creates a distributable application:

- **macOS** -- `.app` bundle with icon
- **Windows** -- Executable with resources

## Next Steps

- [CLI Reference](cli.md) -- All commands and options
- [Configuration](config.md) -- `zapp.config.ts` reference
