# Goal

The goal of this project (Zapp) is to create an alternative to Wails (v3alpha.wails.io), Electron, and Tauri. I explored the desired api and functionality in `./context.md`. Always refer to `./context.md` when building out features.

# Language

I want to use Zen-C which can work with C, C++, and Objective-C. Refer to `./Zen-C.md` for the language reference. Always refer to this doc when you hit a syntax or compilation error to ensure you are following language semantics.

The Zen-C standard lib is here: https://github.com/z-libs/Zen-C/blob/main/docs/std/README.md

# Setup

In `./example` we want to build a test app, like what an end user would do. So I created a sample with a vite/svelte template in the `frontend` directory. `./example/app.zc` is how users will consume and run our framework.

`./src` is where the framework code will live. We are prioritizing and starting with macOS only development with the understanding that we will support Windows in the future.

# Progress

## Logging System (Completed)

- Unified logging module: `src/platform/shared/log.zc`
- Log levels: error, warn, info, debug, trace
- ANSI color support (red, yellow, cyan, gray)
- Per-window sequential worker IDs
- Default log levels: info (dev), warn (prod)
- CLI flags: `--log-level`, `--debug`
- Asset embedding default for `zapp build`
- Binary size optimization with `-Oz` flag

## Windows Log Conversion (Fixed)

- Issue: Zen-C parses content inside `raw {}` blocks even when wrapped in `#ifdef _WIN32`
- Solution: Use separate `raw {}` blocks for each platform, wrapped in `#ifdef` at the top level
- Pattern: `raw { #ifdef _WIN32 ... #endif }` and `raw { #ifndef _WIN32 ... #endif }`

## Discoveries

1. **Zen-C `def` vs `#define`**: Using `def` for constants in Zen-C doesn't make them available inside `raw {}` blocks. Must use C `#define` inside the raw block for use in C code.

2. **Zen-C raw block parsing**: Zen-C parses content inside `raw {}` blocks. Use separate `raw {}` blocks with `#ifdef` at the top level for platform-specific code.

3. **Binary size optimization**: 
   - `-Oz` flag: aggressive size optimization
   - `-flto`: link-time optimization
   - `strip`: removes debug symbols
   - **JSC**: ~200KB (uses system JavaScriptCore framework)
   - **QJS**: ~745KB (embeds QuickJS runtime)

## Bootstrap Scripts

- `bootstrap.sh` (macOS/Linux) - Syncs native code to CLI and rebuilds CLI
- `bootstrap.ps1` (Windows) - Same for Windows
- Usage: `./bootstrap.sh` or `./bootstrap.sh --clean` (also cleans build artifacts)