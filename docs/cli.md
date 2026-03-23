# CLI Reference

All commands are run as `zapp <command> [options]`.

## `zapp init [name]`

Scaffold a new Zapp project.

```bash
zapp init my-app
zapp init my-app --template vanilla
```

| Option | Description |
|--------|-------------|
| `--template <name>` | Project template to use (default: `svelte-ts`) |
| `--root <path>` | Project root directory |

## `zapp dev`

Start development mode. Runs Vite for frontend hot-reloading and compiles the native binary.

```bash
zapp dev
zapp dev --dev-url http://localhost:3000
```

| Option | Description |
|--------|-------------|
| `--root <path>` | Project root directory |
| `--frontend <path>` | Path to frontend source directory |
| `--input <path>` | Path to the Zen-C entry file |
| `--out <path>` | Output path for the compiled binary |
| `--log-level <level>` | Log verbosity level |
| `--dev-url <url>` | Custom dev server URL to connect to |
| `--brotli` | Enable Brotli compression for embedded assets |
| `--embed-assets` | Embed frontend assets into the binary during dev |

## `zapp build`

Compile a production binary with embedded frontend assets.

```bash
zapp build
zapp build --brotli
zapp build --debug
```

| Option | Description |
|--------|-------------|
| `--root <path>` | Project root directory |
| `--frontend <path>` | Path to frontend source directory |
| `--input <path>` | Path to the Zen-C entry file |
| `--out <path>` | Output path for the compiled binary |
| `--log-level <level>` | Log verbosity level |
| `--asset-dir <path>` | Directory containing pre-built frontend assets to embed |
| `--brotli` | Enable Brotli compression for embedded assets |
| `--debug` | Build with debug symbols and web content inspector enabled |

## `zapp package`

Create a distributable application bundle.

```bash
zapp package --brotli
zapp package --skip-build
```

On macOS this produces a `.app` bundle with the configured icon. On Windows it produces a packaged executable.

| Option | Description |
|--------|-------------|
| `--root <path>` | Project root directory |
| `--frontend <path>` | Path to frontend source directory |
| `--input <path>` | Path to the Zen-C entry file |
| `--out <path>` | Output directory for the package |
| `--brotli` | Enable Brotli compression for embedded assets |
| `--skip-build` | Skip the build step and package an existing binary |

## `zapp generate`

Generate Zen-C bindings from the config and frontend source.

```bash
zapp generate
```

| Option | Description |
|--------|-------------|
| `--root <path>` | Project root directory |
| `--frontend <path>` | Path to frontend source directory |
| `--out-dir <path>` | Output directory for generated files |
