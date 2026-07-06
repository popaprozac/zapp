// CEF spike (Task 3) — brotli-direct probe: pre-compress assets/data.json into
// the committed assets/data.json.br the "zapp" scheme handler serves.
//
// Run with Bun (NOT Node): `bun run spikes/cef-macos/compress-assets.ts`
//
// scheme_handler.c serves data.json.br's bytes AS-IS with a
// `Content-Encoding: br` response header — it does not decompress. The point
// of the probe is that Chromium's own network stack decodes br natively, so
// index.html's `fetch("zapp://app/data.json")` sees plain decoded JSON text.
// This script is the one-time (re-run when data.json changes) compression
// step standing in for what a real Zapp asset pipeline would do at build
// time.
import { brotliCompressSync, constants } from "node:zlib";

const here = new URL(".", import.meta.url).pathname;
const rawPath = here + "assets/data.json";
const outPath = here + "assets/data.json.br";

const raw = await Bun.file(rawPath).bytes();
const compressed = brotliCompressSync(raw, {
  params: {
    [constants.BROTLI_PARAM_QUALITY]: constants.BROTLI_MAX_QUALITY,
    [constants.BROTLI_PARAM_SIZE_HINT]: raw.byteLength,
  },
});
await Bun.write(outPath, compressed);

const pct = Math.round((1 - compressed.byteLength / raw.byteLength) * 100);
console.log(
  `[compress-assets] data.json raw=${raw.byteLength}B  br=${compressed.byteLength}B  (${pct}% smaller)`,
);
