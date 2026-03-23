# @zappdev/vite

Vite plugin for Zapp desktop apps. Handles worker discovery, source bundling, and output configuration so your Vite-based frontend integrates seamlessly with the Zapp native runtime.

## Install

```sh
bun add -D @zappdev/vite
```

```sh
npm install -D @zappdev/vite
```

## Usage

```ts
// vite.config.ts
import { defineConfig } from "vite";
import zapp from "@zappdev/vite";

export default defineConfig({
  plugins: [zapp()],
});
```

## Options

| Option       | Type      | Description                        |
| ------------ | --------- | ---------------------------------- |
| `outDir`     | `string`  | Output directory for bundled files |
| `sourceRoot` | `string`  | Root directory of source files     |
| `minify`     | `boolean` | Enable minification                |

## License

MIT
