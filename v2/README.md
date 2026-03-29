# Zapp v2

Desktop app framework. 337 KB binaries. System WebView. Zen-C + TypeScript.

## Architecture

See [SKILLS.md](../SKILLS.md) for the full reference.

```
v2/
├── native/       # Zen-C framework (.zc + .h/.m for ObjC)
├── runtime/      # @zappdev/runtime TypeScript package
├── cli/          # Build tooling (Bun)
├── bootstrap/    # WebView/Worker JS injection (future)
├── vendor/       # txiki.js (git submodule)
└── hello-world/  # Reference example app
```

### Key patterns
- **ObjC in .m files**, Zen-C owns structs/types, accessor functions bridge the gap
- **@cfg(apple)** trampolines in .zc call `darwin_*` functions in .h
- **Two-tier native API**: JSON for JS bridge, typed C for native Zen-C (zero serialization)
- **JSON bridge protocol** with numeric type routing and cancellation
- **Unified event dispatcher** with per-window bitmask optimization
- **Worker engines**: JSC (macOS, 0 KB) or txiki.js (cross-platform, +6 MB)
- **Dialogs, menus, notifications** — full native APIs from both JS and Zen-C
- **Dev .app bundle** — `zapp dev` creates minimal .app with ad-hoc signing

## Running the example

```bash
cd hello-world
bun install
bun run build
./bin/hello-world
```

## Binary sizes

| Config | Size |
|---|---|
| JSC workers | 337 KB |
| txiki.js workers | 6.4 MB |
| JSC + optimizations (-Oz -flto strip) | ~90 KB |

## Developing the framework

Edit files in `native/`, `runtime/`, or `cli/`. Test via `hello-world/`:

```bash
cd hello-world
bun run ../cli/src/zapp-cli.ts build   # builds with latest framework
bun run ../cli/src/zapp-cli.ts dev     # dev mode with Vite HMR
```
