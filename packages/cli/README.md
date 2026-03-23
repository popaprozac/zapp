# @zapp/cli

CLI for building cross-platform desktop apps with Zapp.

## Install

```sh
bun add -D @zapp/cli
```

```sh
npm install -D @zapp/cli
```

## Quick Start

```sh
# Create a new Zapp project
zapp init my-app
cd my-app

# Start the dev server with hot reload
zapp dev

# Build for production
zapp build

# Package into a distributable
zapp package
```

## Commands

| Command    | Description                                      |
| ---------- | ------------------------------------------------ |
| `init`     | Scaffold a new Zapp project                      |
| `dev`      | Start the development server with live reload     |
| `build`    | Compile the native backend and bundle the frontend |
| `package`  | Package the app into a distributable binary       |
| `generate` | Generate bindings and boilerplate code            |

## Options

All build-related commands support:

- `--root` -- project root directory
- `--frontend` -- frontend directory
- `--input` -- build file path (default: `zapp/build.zc`)
- `--out` -- override output binary path
- `--backend` -- backend script path
- `--log-level` -- log verbosity (`error`, `warn`, `info`, `debug`, `trace`)

## License

MIT
