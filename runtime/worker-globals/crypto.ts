// Install web `crypto` global with `getRandomValues` + `subtle` from
// `bare-crypto`.
//
// Note: `bare-crypto` is Node-shaped (`createHash`, `randomBytes`,
// `createCipheriv`, …). The WebCrypto `crypto.subtle.*` surface is
// not 1:1; we expose what bare-crypto provides under those names
// best-effort, and leave anything else for users to import directly
// when they need it.
//
// Also installs `crypto.randomUUID()` since that's a single-line
// adapter on top of randomBytes that's high-traffic in user code.
import { bindGlobal, tryRequire } from "./_install";

const mod = tryRequire("bare-crypto");
if (mod) {
  const cryptoLike: any = {
    // crypto.getRandomValues(typedArray) — fills the buffer in place.
    getRandomValues(arr: ArrayBufferView) {
      if (!arr) throw new TypeError("getRandomValues requires a typed array");
      const bytes: Uint8Array = mod.randomBytes(arr.byteLength);
      new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength).set(bytes);
      return arr;
    },
    // crypto.randomUUID() — RFC 4122 v4. Bare-crypto exposes randomUUID
    // directly on newer versions; fall back to a manual hex assembly.
    randomUUID(): string {
      if (typeof mod.randomUUID === "function") return mod.randomUUID();
      const b = mod.randomBytes(16);
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      const h = (n: number) => n.toString(16).padStart(2, "0");
      return `${h(b[0])}${h(b[1])}${h(b[2])}${h(b[3])}-${h(b[4])}${h(b[5])}-${h(b[6])}${h(b[7])}-${h(b[8])}${h(b[9])}-${h(b[10])}${h(b[11])}${h(b[12])}${h(b[13])}${h(b[14])}${h(b[15])}`;
    },
    // crypto.subtle — best-effort proxy for WebCrypto SubtleCrypto.
    // bare-crypto's API isn't a drop-in: digest works, signing/encryption
    // shapes differ. We expose `digest` here; users needing the full
    // surface should `import * as crypto from 'bare-crypto'` directly
    // and use the Node-shaped methods.
    subtle: {
      async digest(alg: string | { name: string }, data: ArrayBuffer | ArrayBufferView): Promise<ArrayBuffer> {
        const algName = typeof alg === "string" ? alg : alg?.name;
        const nodeName =
          algName === "SHA-1"   ? "sha1"   :
          algName === "SHA-256" ? "sha256" :
          algName === "SHA-384" ? "sha384" :
          algName === "SHA-512" ? "sha512" : null;
        if (!nodeName) throw new Error(`Unsupported digest algorithm: ${algName}`);
        const buf = data instanceof ArrayBuffer
          ? new Uint8Array(data)
          : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        const h = mod.createHash(nodeName);
        h.update(buf);
        const out: Uint8Array = h.digest();
        return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength) as ArrayBuffer;
      },
    },
  };
  bindGlobal("crypto", cryptoLike);
}
