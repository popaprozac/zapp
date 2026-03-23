# @zapp/vite

Vite plugin for Zapp desktop apps. Handles worker discovery, source bundling, and output configuration so your Vite-based frontend integrates seamlessly with the Zapp native runtime.

## Install

```sh
bun add -D @zapp/vite
```

```sh
npm install -D @zapp/vite
```

## Usage

```ts
// vite.config.ts
import { defineConfig } from "vite";
import zapp from "@zapp/vite";

export default defineConfig({
  plugins: [
    zapp({
      outDir: "dist",
      sourceRoot: "src",
      minify: true,
    }),
  ],
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
