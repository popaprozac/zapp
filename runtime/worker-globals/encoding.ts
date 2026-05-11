// Install WHATWG `TextEncoder` / `TextDecoder` from `bare-encoding`.
// Most engines have these built-in; this is the defensive bind for
// minimal contexts.
import { bindGlobal, tryRequire } from "./_install";

const mod = tryRequire("bare-encoding");
if (mod) {
  bindGlobal("TextEncoder", mod.TextEncoder);
  bindGlobal("TextDecoder", mod.TextDecoder);
}
