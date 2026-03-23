# @zappdev/cli

CLI for building cross-platform desktop apps with Zapp.

## Install

```sh
bun add -g @zappdev/cli
```

```sh
npm install -g @zappdev/cli
```

## Quick Start

```sh
# Create a new Zapp project
zapp init my-app
cd my-app
bun install

# Start the dev server with hot reload
zapp dev

# Build for production
zapp build --brotli

# Package into a .app bundle (macOS)
zapp package --brotli
```

## Commands

| Command    | Description                                       |
| ---------- | ------------------------------------------------- |
| `init`     | Scaffold a new Zapp project (any Vite template)   |
| `dev`      | Start dev mode with Vite hot reload + native app  |
| `build`    | Build frontend assets + compile native binary     |
| `package`  | Build and package into a platform bundle (.app)   |
| `generate` | Generate TypeScript bindings from Zen-C services  |

## Common Options

- `--root` — project root directory
- `--frontend` — frontend directory
- `--input` — build file path (default: `zapp/build.zc`)
- `--out` — override output binary path
- `--log-level` — log verbosity (`error`, `warn`, `info`, `debug`, `trace`)

## Prerequisites

- [Zen-C compiler](https://github.com/zenc-lang/zenc) (`zc`) in your PATH
- [Bun](https://bun.sh) runtime

## License

MIT
