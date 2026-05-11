// Install WHATWG `URL` + `URLSearchParams` as globals from `bare-url`.
//
// Most engines already expose URL globally; this is a defensive bind so
// minimal worker contexts (or older engine builds) still get the API.
//
// Required by `bare-fetch` and `bare-ws`, so this install file is
// imported first by `worker-globals.ts`.
import { bindGlobal, tryRequire } from "./_install";

const mod = tryRequire("bare-url");
if (mod) {
  bindGlobal("URL", mod.URL ?? mod.default?.URL ?? mod.default);
  bindGlobal("URLSearchParams", mod.URLSearchParams ?? mod.default?.URLSearchParams);
}
