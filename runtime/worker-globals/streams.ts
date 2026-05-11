// Install WHATWG stream globals (`ReadableStream`, `WritableStream`,
// `TransformStream`) from `bare-stream/web`.
//
// `bare-stream` exports both Node-shaped classic streams and a `web`
// subpath with WHATWG implementations. We only globalify the WHATWG
// surface here — Node-shape can still be imported explicitly by code
// that wants it (`import { Readable } from 'bare-stream'`).
import { bindGlobal, tryRequire } from "./_install";

// WHATWG streams live under `bare-stream/web` in current versions; older
// versions export them at the package root. Try the subpath first.
const mod = tryRequire("bare-stream/web") ?? tryRequire("bare-stream");
if (mod) {
  bindGlobal("ReadableStream",  mod.ReadableStream);
  bindGlobal("WritableStream",  mod.WritableStream);
  bindGlobal("TransformStream", mod.TransformStream);
  if (mod.ReadableStreamDefaultReader)
    bindGlobal("ReadableStreamDefaultReader", mod.ReadableStreamDefaultReader);
  if (mod.WritableStreamDefaultWriter)
    bindGlobal("WritableStreamDefaultWriter", mod.WritableStreamDefaultWriter);
}
