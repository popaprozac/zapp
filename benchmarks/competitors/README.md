# Competitor Hello World Apps

To run live competitor benchmarks (`./bench.sh 10 --all`), build equivalent hello-world apps in each directory.

Each app should: open 1 window, show "Hello World" with a text input + button, call a backend function on click.

## Setup

### Tauri v2
```bash
cd tauri
npm create tauri-app@latest hello-world
cd hello-world
npm install
npm run tauri build
# Binary at: src-tauri/target/release/hello-world
# Copy to: tauri/bin
```
Docs: https://v2.tauri.app/start/create-project/

### Wails v3
```bash
# Install (requires Go 1.23+)
go install github.com/wailsapp/wails/v3/cmd/wails3@latest

cd wails
wails3 create -n hello-world
cd hello-world
wails3 build
# Binary at: bin/hello-world
# Copy to: wails/bin
```
Docs: https://v3alpha.wails.io/getting-started/installation/

### Electrobun
```bash
# Requires Bun
cd electrobun
bunx electrobun init hello-world
cd hello-world
bun start  # dev mode
# For release: see https://blackboard.sh/electrobun/docs/apis/cli/build-configuration/
```
Repo: https://github.com/blackboardsh/electrobun
Docs: https://blackboard.sh/electrobun/docs/guides/quick-start/

### Electron
```bash
cd electron
npx create-electron-app@latest hello-world
cd hello-world
npx electron-builder --dir
# Binary at: dist/mac-arm64/hello-world.app/Contents/MacOS/hello-world
# Copy to: electron/bin
```

## What We Measure

All apps do the same thing:
1. Open a single window (600x400)
2. Show a heading, text input, and button
3. Button calls a backend function that echoes the input
4. No tray, no extra windows, no workers

This ensures an apples-to-apples comparison of framework overhead.
