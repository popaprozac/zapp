// Install WHATWG `fetch`, `Request`, `Response`, `Headers`, and (when
// the package provides them) `FormData` / `Blob` from `bare-fetch`.
//
// `bare-fetch` is the holepunch-maintained WHATWG Fetch implementation
// for Bare runtimes. Adding it to your project's package.json + linking
// the binding via the CLI's bare-modules build is the only opt-in step.
// Static `import` (not the `tryRequire` helper) so Vite bundles
// bare-fetch's exports directly into the worker. `tryRequire` relies
// on a runtime `require` global, but bare evaluates worker bundles
// via `js_run_script` in *script* context where no `require` exists
// — so the runtime path always returns `null` and the shim silently
// no-ops. With a static import, the resolved exports become locals
// at bundle time and `bindGlobal` always sees them.
//
// Missing bare-fetch surfaces as a bundle-time error, which is
// strictly better UX than a runtime crash: `bun install bare-fetch`
// is the obvious next step. The CLI's `verifyWorkerModules` also
// warns ahead of the bundle step.
import { bindGlobal } from "./_install";
// Default import (not `import * as`) is important for Rolldown's
// CJS interop: bare-fetch is CJS (`module.exports = function fetch`),
// and a namespace import on a CJS package gets externalized in the
// output bundle — leaving a literal `import * as e from "bare-fetch"`
// in the .mjs that triggers a SyntaxError in `js_run_script` script
// context. Default import yields the unwrapped module.exports value
// directly + lets Rolldown inline the source as expected.
// @ts-expect-error — bare-fetch has no @types
import bareFetch from "bare-fetch";

// bare-fetch ships as `module.exports = exports = function fetch(...)`
// — the module IS the fetch function, with `.Request` / `.Response`
// / `.Headers` hung off it.
const fetchFn: any = bareFetch;
bindGlobal("fetch",     fetchFn);
bindGlobal("Request",   fetchFn.Request);
bindGlobal("Response",  fetchFn.Response);
bindGlobal("Headers",   fetchFn.Headers);
if (fetchFn.FormData) bindGlobal("FormData", fetchFn.FormData);
if (fetchFn.Blob)     bindGlobal("Blob", fetchFn.Blob);
