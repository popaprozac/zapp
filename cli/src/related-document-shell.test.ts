import { expect, test } from "bun:test";
import { createServer } from "vite";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { zapp } from "../../vite/src/index";
import { RELATED_DOCUMENT_SHELL_HTML, RELATED_DOCUMENT_SHELL_PATH } from "../../bootstrap/related-document";

test("the real Vite stack serves the private shell without app or HMR transforms", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zapp-related-vite-"));
  let server: Awaited<ReturnType<typeof createServer>> | undefined;
  try {
    await writeFile(path.join(root, "index.html"), '<!doctype html><title>Application entry</title>');
    server = await createServer({ root, configFile: false, plugins: [zapp()],
      server: { host: "127.0.0.1", port: 0 }, logLevel: "silent" });
    await server.listen();
    const address = server.httpServer!.address();
    if (address === null || typeof address === "string") throw new Error("missing Vite port");
    const origin = `http://127.0.0.1:${address.port}`;
    for (const suffix of ["", "?reservation=opaque"]) {
      const response = await fetch(`${origin}${RELATED_DOCUMENT_SHELL_PATH}${suffix}`);
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("x-content-type-options")).toBe("nosniff");
      expect(await response.text()).toBe(RELATED_DOCUMENT_SHELL_HTML);
    }
    const head = await fetch(`${origin}${RELATED_DOCUMENT_SHELL_PATH}`, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(Number(head.headers.get("content-length"))).toBe(Buffer.byteLength(RELATED_DOCUMENT_SHELL_HTML));
    expect(await head.text()).toBe("");
    const post = await fetch(`${origin}${RELATED_DOCUMENT_SHELL_PATH}`, { method: "POST" });
    expect(post.status).toBe(405);
    expect(post.headers.get("allow")).toBe("GET, HEAD");
    // The normal app path still passes through Vite's HTML transform.
    const app = await (await fetch(`${origin}/`)).text();
    expect(app).toContain("Application entry");
    expect(app).toContain("/@vite/client");
  } finally {
    await server?.close();
    await rm(root, { recursive: true, force: true });
  }
}, 20_000);
