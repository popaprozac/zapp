// Adversarial security gate for the native->JS literal encoder (finding #2, P0).
//
// This does NOT unit-test jslit.c's internals in isolation — it compiles the
// REAL native/shared/jslit.c standalone, calls the REAL zapp_js_lit_dup via
// bun:ffi, builds the REAL IIFE shape the Nim dispatch layer emits
// (`(function(){var b=globalThis[Symbol.for('zapp.bridge')];if(b&&b._onEvent)
// b._onEvent(<litName>,<litPayload>);})()`), and `eval`s it against a stub
// bridge. Every adversarial input must (a) round-trip byte-for-byte through
// the stub bridge's recorded payload and (b) never flip a `__compromised`
// sentinel planted alongside the eval. If any input can break out of the
// literal, this test fails.
import { test, expect, beforeAll } from "bun:test";
import { dlopen, FFIType, suffix, CString } from "bun:ffi";
import { $ } from "bun";

let encode: (s: string) => string;

beforeAll(async () => {
  const lib = `${process.env.TMPDIR ?? "/tmp"}/libjslit_test.${suffix}`;
  await $`cc -shared -fPIC -O2 -o ${lib} native/shared/jslit.c`.quiet();
  const { symbols } = dlopen(lib, {
    zapp_js_lit_dup: { args: [FFIType.cstring], returns: FFIType.ptr },
  });
  encode = (s: string) => {
    const buf = Buffer.from(s + "\0", "utf8"); // NUL-terminated C string in
    const ptr = symbols.zapp_js_lit_dup(buf);
    if (!ptr) throw new Error("encoder returned NULL");
    return new CString(ptr).toString(); // read the complete literal (quotes included)
  };
});

// Build the ACTUAL native IIFE shape and eval it against a stub bridge; assert
// the payload round-trips exactly and NO injected side effect fired.
function deliverAndRecover(input: string): { recovered: string | undefined; compromised: boolean } {
  const litName = encode("evt:test");
  const litPayload = encode(input); // literals include their own quotes
  const iife =
    `(function(){var b=globalThis[Symbol.for('zapp.bridge')];` +
    `if(b&&b._onEvent)b._onEvent(${litName},${litPayload});})()`;
  let recovered: string | undefined;
  (globalThis as any)[Symbol.for("zapp.bridge")] = {
    _onEvent: (_n: string, p: string) => {
      recovered = p;
    },
  };
  (globalThis as any).__compromised = false;
  // eslint-disable-next-line no-eval
  (0, eval)(iife);
  return { recovered, compromised: (globalThis as any).__compromised === true };
}

// NOTE on the two U+2028/U+2029 entries: the brief's source embeds the raw
// separator bytes directly in the string literal (legal since ES2019 allows
// unescaped U+2028/U+2029 inside string literals). We use \u2028/\u2029
// escape sequences here instead -- identical runtime string value, safer to
// persist through editors/git/terminals that mangle invisible line/paragraph
// separators.
const ADVERSARIAL: string[] = [
  "plain",
  "a'b",
  'a"b',
  "a\\b",
  "line1\nline2",
  "cr\rhere",
  "tab\there",
  "\u2028sep",
  "para\u2029graph",
  "');globalThis.__compromised=true;//",
  '"});globalThis.__compromised=true;({"',
  "zapp://open?u='+({}).constructor",
  "Notification: it's here \u2014 \u2028 done",
  "not json at all { [ ",
  "\uD800lone-surrogate",
  "x".repeat(4096),
];

test.each(ADVERSARIAL)("round-trips exactly + no side effect: %j", (input) => {
  const { recovered, compromised } = deliverAndRecover(input);
  expect(compromised).toBe(false);
  // A lone UTF-16 surrogate (no low surrogate partner) has no valid UTF-8
  // encoding. `Buffer.from(input, "utf8")` -- the same lossy WHATWG UTF-8
  // encode step the real native bridge boundary performs when handing a JS
  // string to native code -- replaces it with U+FFFD *before* jslit.c ever
  // sees the bytes. So the byte-for-byte guarantee holds for the UTF-8-
  // normalized form of the input; for every entry except the lone-surrogate
  // one, that normalized form is identical to the original input (this is a
  // no-op for well-formed UTF-16), so this does not weaken the assertion for
  // any realistic payload (URLs, notification text, JSON, 4KB blobs, etc).
  const expected = Buffer.from(input, "utf8").toString("utf8");
  expect(recovered).toBe(expected);
});

// Sanity-check that the U+2028/U+2029 round-trip cases above are actually
// exercising the escape branch, not passing vacuously.
//
// IMPORTANT FINDING (verified empirically while building this gate): since
// ES2019's "JSON superset" change, raw (unescaped) U+2028/U+2029 are legal
// *inside* a JS string literal on modern engines -- a naive, unescaped
// single-quoted literal containing a raw separator neither throws nor
// mis-recovers under Bun's own JSC-based eval(). So the round-trip
// assertions for the two U+2028/U+2029 entries above would still pass even
// if jslit.c's special-case for them were deleted entirely (falling through
// to plain byte passthrough) -- they do not, by themselves, prove the escape
// branch is exercised on this engine. (What they still prove: no injection
// and correct recovery either way.)
//
// This test asserts the one thing that DOES discriminate the escape branch:
// the encoder's OUTPUT must contain the literal 6-character escape sequences
// for U+2028/U+2029, not the raw 3-byte UTF-8 separator bytes. Deleting the
// special-case in jslit.c makes THIS test fail (confirmed manually).
test("encoder emits \\u2028/\\u2029 escapes, not raw separator bytes -- proves the round-trip cases aren't passing vacuously", () => {
  const litLS = encode("\u2028");
  const litPS = encode("\u2029");
  expect(litLS).toBe('"\\u2028"');
  expect(litPS).toBe('"\\u2029"');
  expect(litLS.includes("\u2028")).toBe(false);
  expect(litPS.includes("\u2029")).toBe(false);
});
